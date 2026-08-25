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
-- THE RULE is a pure function of its arguments -- no globals read, no DB, no
-- client API. `de.Value` takes the pricer as a parameter for that reason: it
-- is testable without either, and a caller that needs a stricter price source
-- can pass one.
--
-- The LAST SECTION of this file is not pure, and is fenced off accordingly:
-- it watches the player disenchant things and writes what it sees to the DB.
-- That is the only source of item levels that works for Turtle content the
-- shipped table has never heard of, so it lives beside the rule it feeds.

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
function de.ItemLevel(itemId, quality)
    -- What the player has actually SEEN outranks anything shipped. It is
    -- evidence from the server they are playing on, where the shipped table
    -- is vanilla data with a partial view of Turtle's items -- and it is the
    -- only thing that can ever answer for the two thirds of Turtle's custom
    -- items the table has never heard of.
    --
    -- Accepted only when the evidence names ONE band. Two candidates is not a
    -- weak answer worth rounding off: the bands either side of a dust differ
    -- by more than double in yield, so picking one would be a coin flip
    -- dressed as a measurement. It stays unanswered until another disenchant
    -- separates them.
    if quality then
        local band, count = de.BandFromObservation(itemId, quality)
        if band and count == 1 then return band, "observed" end
    end
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
    local ilvl, source = de.ItemLevel(itemId, info.quality)
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

-- ---------------------------------------------------------------------------
-- The inverse: materials seen -> which band the item is in
-- ---------------------------------------------------------------------------

-- Every material a (quality, band) can produce, DERIVED from BANDS itself and
-- cached on first use.
--
-- Derived rather than written out, because a second hand-kept map of "which
-- materials come from which band" is precisely the kind of duplicate that goes
-- stale in silence -- regenerate BANDS and the copy still looks plausible
-- while answering for a table that no longer exists.
local MATSET = nil
local function MaterialSets()
    if MATSET then return MATSET end
    MATSET = {}
    for quality, byBand in pairs(BANDS) do
        local perBand = {}
        for band, rec in pairs(byBand) do
            local set, lists, li = {}, { rec.a, rec.w }, 1
            while li <= 2 do
                local rows = lists[li]
                if rows then
                    local i, n = 1, table.getn(rows)
                    while i <= n do
                        set[rows[i][1]] = true
                        i = i + 1
                    end
                end
                li = li + 1
            end
            perBand[band] = set
        end
        MATSET[quality] = perBand
    end
    return MATSET
end

-- Which bands are still consistent with the materials seen so far.
--
-- Returns the LOWEST consistent band and HOW MANY are consistent. The count is
-- the point: one disenchant is often not enough. An essence names its band
-- outright, but a dust covers two or three -- Strange Dust spans bands 15, 20
-- and 25. Of the 30 material/quality combinations this table can produce, 21
-- pin a band on their own and 9 do not, so evidence has to accumulate rather
-- than be believed on the first result.
function de.BandCandidates(quality, seen)
    if not quality or not seen then return nil, 0 end
    local sets = MaterialSets()[quality]
    if not sets then return nil, 0 end
    local best, count, i, n = nil, 0, 1, table.getn(LADDER)
    while i <= n do
        local band = LADDER[i]
        local set = sets[band]
        if set then
            local ok, any = true, false
            for matId in pairs(seen) do
                any = true
                if not set[matId] then ok = false end
            end
            if ok and any then
                count = count + 1
                if not best then best = band end
            end
        end
        i = i + 1
    end
    return best, count
end

-- The same question, asked of what this realm has actually observed.
function de.BandFromObservation(itemId, quality)
    if not itemId or not A.db or not A.db.Disenchants then return nil, 0 end
    local rec = A.db.Disenchants(itemId)
    if not rec then return nil, 0 end
    local seen, any = {}, false
    for matId in pairs(rec) do
        seen[matId] = true
        any = true
    end
    if not any then return nil, 0 end
    return de.BandCandidates(quality, seen)
end

-- ---------------------------------------------------------------------------
-- Learning from play -- NOT pure; see the note in the header
-- ---------------------------------------------------------------------------

-- The 24 enchanting reagents. A disenchant produces exactly one stack of one
-- of these and nothing else, which is the fact attribution leans on hardest.
--
-- Written out rather than derived from BANDS because BANDS has no epics, and
-- so cannot name Nexus Crystal -- and an epic disenchant is exactly the kind
-- of observation worth keeping even while we decline to VALUE epics.
local REAGENT = {
    [10940] = true, [11083] = true, [11137] = true, [11176] = true,
    [16204] = true,
    [10938] = true, [10939] = true, [10998] = true, [11082] = true,
    [11134] = true, [11135] = true, [11174] = true, [11175] = true,
    [16202] = true, [16203] = true,
    [10978] = true, [11084] = true, [11138] = true, [11139] = true,
    [11177] = true, [11178] = true, [14343] = true, [14344] = true,
    [20725] = true,
}

-- How long a loot window may arrive after the click and still be attributed.
local WINDOW = 15

-- What the last item-targeted click was aimed at.
local watch = { link = nil, at = 0, armed = false }

-- HOW THIS KNOWS WHAT WAS DISENCHANTED, and why it does not read the spell.
--
-- 1.12 reports no "you disenchanted X". The item is never named: a spell is
-- cast and then a bag item is clicked, and neither step says what it was. The
-- only handle is the click, so `PickupContainerItem` / `PickupInventoryItem`
-- are hooked to remember what the click landed on. Verified against the real
-- 1.12.1 ContainerFrame.lua: a plain left click is `PickupContainerItem` at
-- line 580, and there is no `SpellCanTargetItem` branch on this client -- that
-- arrived later.
--
-- Enchantrix gates this on SPELLCAST_START matching the localised spell name.
-- We deliberately do NOT, for two reasons: the name is localised, and whether
-- Turtle's Disenchant produces a cast at all is not something the client
-- source answers. Instead attribution requires all four of:
--
--   1. the click happened while a spell was awaiting an item target
--      (`SpellIsTargeting`), which is true of Disenchant and of nothing the
--      player does by accident;
--   2. the item clicked is one that CAN be disenchanted -- which is what stops
--      a lockbox being "learned" from the shard someone picked out of it;
--   3. a loot window inside WINDOW seconds;
--   4. EVERY loot slot is an enchanting reagent.
--
-- (4) is the discriminator. Enchanting a bracer opens no loot window at all;
-- a lockbox yields things that are not reagents. Together these need no spell
-- name and work whether or not a cast bar exists.
--
-- Cost: O(1) per click, and bounded by loot-slot count on LOOT_OPENED, which
-- is one or two. Nothing here walks bags or calls GetItemInfo per item, so
-- HARD RULE 16 is satisfied by construction rather than by a dirty flag.
local function RememberTarget(link)
    watch.link  = link
    watch.at    = (GetTime and GetTime()) or 0
    -- Read BEFORE the original runs -- the client consumes the pending spell
    -- inside it, so afterwards this is always false.
    watch.armed = (SpellIsTargeting and SpellIsTargeting()) and true or false
end

local function Forget()
    watch.link, watch.armed = nil, false
end

-- LOOT_OPENED: attribute the loot to the remembered item, or do nothing.
function de.OnLootOpened()
    if not watch.armed or not watch.link then return end
    local now = (GetTime and GetTime()) or 0
    if now - watch.at > WINDOW then return Forget() end

    local itemId = util and util.ItemIdFromLink(watch.link)
    local info = itemId and util.ItemInfo(watch.link)
    if not info or not de.CanDisenchant(info.quality, info.equipLoc, itemId) then
        return Forget()
    end

    local slots = (GetNumLootItems and GetNumLootItems()) or 0
    if slots < 1 then return Forget() end

    -- Collected first, recorded only once EVERY slot has passed. A partial
    -- write from a loot window that turns out not to be a disenchant would be
    -- indistinguishable from a real observation afterwards.
    local found, i = {}, 1
    while i <= slots do
        if not (LootSlotIsItem and LootSlotIsItem(i)) then return Forget() end
        local link = GetLootSlotLink and GetLootSlotLink(i)
        local matId = link and util.ItemIdFromLink(link)
        if not matId or not REAGENT[matId] then return Forget() end
        local _, _, quantity = GetLootSlotInfo(i)
        table.insert(found, { matId, quantity or 1 })
        i = i + 1
    end

    local f, n = 1, table.getn(found)
    while f <= n do
        A.db.RecordDisenchant(itemId, found[f][1], found[f][2])
        f = f + 1
    end
    Forget()
end

-- Save-and-replace hooks (HARD RULE 7 -- no hooksecurefunc on 1.12).
--
-- We call PickupContainerItem ourselves in sell.PlaceFromBag, so this sees our
-- own calls too. They are harmless: no spell is targeting during a post, so
-- `armed` is false and nothing is ever attributed. There is a test for that
-- specifically, because it is the kind of interaction that bites a year later.
function de.InstallHooks()
    if de.hooked then return end
    de.hooked = true

    local origContainer = PickupContainerItem
    PickupContainerItem = function(bag, slot)
        RememberTarget(GetContainerItemLink and GetContainerItemLink(bag, slot))
        return origContainer(bag, slot)
    end

    local origInventory = PickupInventoryItem
    PickupInventoryItem = function(slot)
        RememberTarget(GetInventoryItemLink
            and GetInventoryItemLink("player", slot))
        return origInventory(slot)
    end
end

if A.RegisterEvent then
    A.RegisterEvent("LOOT_OPENED", function() de.OnLootOpened() end)
    -- A cast that never completed disenchanted nothing. Harmless if this
    -- client never fires them -- attribution does not depend on it.
    A.RegisterEvent("SPELLCAST_FAILED", Forget)
    A.RegisterEvent("SPELLCAST_INTERRUPTED", Forget)
end
if A.OnLoad then
    A.OnLoad(function() de.InstallHooks() end)
end

-- ---------------------------------------------------------------------------
-- The required-level audit
-- ---------------------------------------------------------------------------
--
-- WHAT THIS IS FOR. There is a fourth possible source of item level, below the
-- shipped table and below what the player has seen: `minLevel`, the level an
-- item must be worn at, which 1.12 DOES give us. aux uses it -- it feeds
-- GetItemInfo's slot 4 straight into a table that wants item level -- and this
-- addon has refused to, on the grounds that the disenchant bands are narrow
-- enough that guessing wrong gives the wrong MATERIAL TIER rather than a
-- slightly wrong number.
--
-- That refusal was reasoning, not measurement. This measures it: for every
-- item whose real level we ship, compare the band its item level gives against
-- the band its required level would have given.
--
-- It cannot be measured anywhere but in a client, because `minLevel` comes
-- from GetItemInfo and GetItemInfo only answers for items that client has
-- cached. That is also the audit's main limitation and why `uncached` is
-- reported rather than quietly skipped: a run that only saw two hundred items
-- has measured two hundred items, not the game.

-- How many ids to classify per frame. The walk is thousands of GetItemInfo
-- calls; doing them in one go is a visible freeze, so it is spread over frames
-- the way the scanner spreads its pages.
local AUDIT_PER_TICK = 300

-- Would required level have landed in the right band? PURE, so the judgement
-- can be tested without a client even though the data cannot be gathered
-- without one.
--
--   nil          -- the item's real level is off the ladder; nothing to judge
--   "no-guess"   -- required level yields no band at all (an item with no
--                   level requirement). The fallback would decline, which is
--                   a SAFE failure and must not be counted as a wrong answer
--   "same"       -- it would have been right
--   "off-by-one" -- one band out: the neighbouring material tier
--   "worse"      -- further than that
function de.CompareBands(ilvl, minLevel)
    local truth = de.Band(ilvl)
    if not truth then return nil end
    local guess = de.Band(minLevel)
    if not guess then return "no-guess" end
    if guess == truth then return "same" end
    local ti, gi, i, n = nil, nil, 1, table.getn(LADDER)
    while i <= n do
        if LADDER[i] == truth then ti = i end
        if LADDER[i] == guess then gi = i end
        i = i + 1
    end
    if not ti or not gi then return "worse" end
    if math.abs(ti - gi) == 1 then return "off-by-one" end
    return "worse"
end

de.driver = CreateFrame("Frame", "AegisExchangeDisenchantDriver")
de.driver:Hide()

-- Walk the shipped table, one chunk per frame.
function de.AuditStep()
    local a = de.audit
    if not a then de.driver:Hide() return end
    local n = 0
    while n < AUDIT_PER_TICK do
        local key, ilvl = next(A.ilvlData or {}, a.key)
        if key == nil then
            de.driver:Hide()
            de.audit = nil
            if a.onDone then a.onDone(a.tally, a.considered, a.done) end
            return
        end
        a.key = key
        a.done = a.done + 1
        local info = util and util.ItemInfo(key)
        if not info then
            -- Not in this client's cache. Counted, never guessed at.
            a.tally.uncached = a.tally.uncached + 1
        elseif not de.CanDisenchant(info.quality, info.equipLoc, key) then
            -- The fallback would never be consulted for this item, so it
            -- would tell us nothing about how good the fallback is.
            a.tally.skipped = a.tally.skipped + 1
        else
            local verdict = de.CompareBands(ilvl, info.minLevel)
            if verdict then
                a.considered = a.considered + 1
                a.tally[verdict] = a.tally[verdict] + 1
            end
        end
        n = n + 1
    end
    if a.onProgress then a.onProgress(a.done) end
end

de.driver:SetScript("OnUpdate", function() de.AuditStep() end)

function de.AuditStart(onProgress, onDone)
    if de.audit then return false end
    if not A.ilvlData or not next(A.ilvlData) then return false end
    de.audit = {
        key = nil, done = 0, considered = 0,
        onProgress = onProgress, onDone = onDone,
        tally = {
            same = 0, ["off-by-one"] = 0, worse = 0,
            ["no-guess"] = 0, uncached = 0, skipped = 0,
        },
    }
    de.driver:Show()
    return true
end

-- The audit's answer, as display lines plus a one-word verdict. PURE.
--
-- The verdict is the decision the brief asked this to settle:
--
--   "adopt"   -- required level is right often enough to be a last-resort
--                source for the FILTERS, never for advice
--   "reject"  -- it is noise wearing a number's clothes; the unanswered path
--                already handles those rows honestly
--   "unclear" -- too few items were cached to say anything
--
-- A wrong band is not a near miss. Bands are one material tier wide, so
-- "off-by-one" means Dream Dust where the answer was Illusion Dust -- which is
-- why it is counted against the fallback exactly as hard as "worse".
function de.AuditSummary(tally, considered)
    if not tally then return nil, "unclear" end
    considered = considered or 0
    local lines = {}
    if considered < 200 then
        table.insert(lines, "Only " .. considered .. " item(s) could be judged"
            .. " -- too few to conclude anything. Browse the auction house to"
            .. " warm the item cache and run it again.")
        table.insert(lines, "uncached: " .. tally.uncached)
        return lines, "unclear"
    end
    local right = tally.same
    local pct = math.floor((right / considered) * 1000 + 0.5) / 10
    table.insert(lines, "judged " .. considered .. " disenchantable item(s)")
    table.insert(lines, "  right band:  " .. right .. "  (" .. pct .. "%)")
    table.insert(lines, "  one tier out: " .. tally["off-by-one"])
    table.insert(lines, "  further out:  " .. tally.worse)
    table.insert(lines, "  no answer:    " .. tally["no-guess"]
        .. "  (safe -- it would decline)")
    table.insert(lines, "  uncached:     " .. tally.uncached
        .. "  (not judged)")
    local verdict = "reject"
    if pct >= 95 then verdict = "adopt" end
    return lines, verdict, pct
end
