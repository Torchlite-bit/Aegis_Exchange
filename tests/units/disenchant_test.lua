-- Aegis: Exchange -- tests/units/disenchant_test.lua
--
-- The disenchant rule: item level + quality + weapon-or-armour -> materials.
--
-- WHAT THIS IS REALLY GUARDING. core/disenchant.lua answers a question the
-- 1.12 client cannot: what an item breaks into. A wrong answer here is not a
-- cosmetic slip -- it tells someone an item is worth destroying. So the two
-- things under test are the ARITHMETIC (does an expectation actually weight
-- by chance) and the SHAPE OF IGNORANCE (does the file say "I do not know"
-- in every case where it genuinely does not).
--
-- The band constants themselves are GENERATED, by tools/gen_disenchant.py,
-- from 8.8M observed disenchants. This suite therefore does not restate them
-- -- restating generated numbers only proves the paste worked. It asserts
-- the things that must hold whatever the generator emits: probabilities that
-- sum to one, materials drawn from the 24 real enchanting reagents, a dust
-- ladder that climbs in the right order, and armour that is dust-led where
-- weapons are essence-led.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
local de = A.de

local ARMOUR, WEAPON = "INVTYPE_CHEST", "INVTYPE_2HWEAPON"
local GREEN, BLUE, PURPLE = 2, 3, 4

-- The 24 enchanting reagents, and nothing else, may appear in a yield.
local REAGENT = {
    [10940] = "Strange Dust",  [11083] = "Soul Dust",
    [11137] = "Vision Dust",   [11176] = "Dream Dust",
    [16204] = "Illusion Dust",
    [10938] = "Lesser Magic",  [10939] = "Greater Magic",
    [10998] = "Lesser Astral", [11082] = "Greater Astral",
    [11134] = "Lesser Mystic", [11135] = "Greater Mystic",
    [11174] = "Lesser Nether", [11175] = "Greater Nether",
    [16202] = "Lesser Eternal",[16203] = "Greater Eternal",
    [10978] = "Sm Glimmering", [11084] = "Lg Glimmering",
    [11138] = "Sm Glowing",    [11139] = "Lg Glowing",
    [11177] = "Sm Radiant",    [11178] = "Lg Radiant",
    [14343] = "Sm Brilliant",  [14344] = "Lg Brilliant",
    [20725] = "Nexus Crystal",
}
local DUST = {
    [10940] = true, [11083] = true, [11137] = true, [11176] = true,
    [16204] = true,
}
local SHARD = {
    [10978] = true, [11084] = true, [11138] = true, [11139] = true,
    [11177] = true, [11178] = true, [14343] = true, [14344] = true,
    [20725] = true,
}

local ALL_BANDS = { 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65 }

local function top(rows)
    return rows and rows[1] and rows[1].itemId or nil
end

-- ---------------------------------------------------------------------------
H.section("de.Band -- every boundary, and the ceiling")
-- ---------------------------------------------------------------------------

-- Each band is claimed by its UPPER bound, so the pair either side of every
-- boundary must land in different bands. An off-by-one here moves an item a
-- whole material tier, which is the difference between Strange Dust and Soul
-- Dust -- not a small error, a wrong answer.
local prev = 1
for i = 1, table.getn(ALL_BANDS) do
    local b = ALL_BANDS[i]
    H.eq("ilvl " .. b .. " is band " .. b, de.Band(b), b)
    H.eq("ilvl " .. (b - 1) .. " is still band " .. b, de.Band(b - 1), b)
    if i > 1 then
        H.eq("ilvl " .. (prev + 1) .. " has left band " .. prev,
             de.Band(prev + 1), b)
    end
    prev = b
end

H.eq("ilvl 1 lands in the first band", de.Band(1), 15)
H.isNil("ilvl 66 is off the end", de.Band(66))
H.isNil("ilvl 99 is off the end -- Turtle goes this high", de.Band(99))
H.isNil("ilvl 0 is not a level", de.Band(0))
H.isNil("a nil level is not a level", de.Band(nil))
H.isNil("a string is not a level", de.Band("40"))

-- ---------------------------------------------------------------------------
H.section("de.Class -- every equip slot the client can report")
-- ---------------------------------------------------------------------------

local WEAPON_SLOTS = {
    "INVTYPE_2HWEAPON", "INVTYPE_WEAPON", "INVTYPE_WEAPONMAINHAND",
    "INVTYPE_WEAPONOFFHAND", "INVTYPE_RANGED", "INVTYPE_RANGEDRIGHT",
    "INVTYPE_THROWN",
}
local ARMOUR_SLOTS = {
    "INVTYPE_HEAD", "INVTYPE_NECK", "INVTYPE_SHOULDER", "INVTYPE_BODY",
    "INVTYPE_CHEST", "INVTYPE_ROBE", "INVTYPE_WAIST", "INVTYPE_LEGS",
    "INVTYPE_FEET", "INVTYPE_WRIST", "INVTYPE_HAND", "INVTYPE_FINGER",
    "INVTYPE_TRINKET", "INVTYPE_CLOAK", "INVTYPE_HOLDABLE", "INVTYPE_SHIELD",
    "INVTYPE_RELIC", "INVTYPE_TABARD",
}
for i = 1, table.getn(WEAPON_SLOTS) do
    H.eq(WEAPON_SLOTS[i] .. " is a weapon", de.Class(WEAPON_SLOTS[i]), "w")
end
for i = 1, table.getn(ARMOUR_SLOTS) do
    H.eq(ARMOUR_SLOTS[i] .. " is armour", de.Class(ARMOUR_SLOTS[i]), "a")
end
-- A shield is ARMOUR here. aux files it as a weapon; the observations do not
-- agree with aux, and this is the kind of one-line disagreement that is worth
-- pinning so it cannot drift back silently.
H.eq("a shield is armour, not a weapon", de.Class("INVTYPE_SHIELD"), "a")
H.isNil("an empty equip slot is neither", de.Class(""))
H.isNil("a bag is neither", de.Class("INVTYPE_BAG"))
H.isNil("nil is neither", de.Class(nil))

-- ---------------------------------------------------------------------------
H.section("de.CanDisenchant")
-- ---------------------------------------------------------------------------

H.check("a green chest can", de.CanDisenchant(GREEN, ARMOUR) == true)
H.check("a blue weapon can", de.CanDisenchant(BLUE, WEAPON) == true)
H.check("an epic can (whether we can VALUE it is another question)",
        de.CanDisenchant(PURPLE, ARMOUR) == true)
H.check("a grey cannot", de.CanDisenchant(0, ARMOUR) == false)
H.check("a white cannot", de.CanDisenchant(1, ARMOUR) == false)
H.check("a legendary cannot", de.CanDisenchant(5, ARMOUR) == false)
H.check("an artifact cannot", de.CanDisenchant(6, ARMOUR) == false)
H.check("a green with no equip slot cannot -- a potion is not gear",
        de.CanDisenchant(GREEN, "") == false)
H.check("a nil quality cannot", de.CanDisenchant(nil, ARMOUR) == false)
H.check("a string quality cannot", de.CanDisenchant("2", ARMOUR) == false)

-- The exception list: items that pass every rule and still yield nothing.
-- No rule predicts these, so if the list is lost nothing else notices.
local NEVER_IDS = { 20406, 20407, 20408, 11287, 11288, 11289, 11290 }
for i = 1, table.getn(NEVER_IDS) do
    H.check("item " .. NEVER_IDS[i] .. " is on the never list",
            de.CanDisenchant(GREEN, ARMOUR, NEVER_IDS[i]) == false)
    H.isNil("...and yields nothing",
            de.Yield(40, GREEN, ARMOUR, NEVER_IDS[i]))
    H.isNil("...and is worth nothing",
            de.Value(40, GREEN, ARMOUR, NEVER_IDS[i],
                     function() return 100 end))
end
H.check("an ordinary id is not on the never list",
        de.CanDisenchant(GREEN, ARMOUR, 12345) == true)

-- ---------------------------------------------------------------------------
H.section("de.Yield -- when it must say nothing")
-- ---------------------------------------------------------------------------

H.isNil("above the ladder there is no answer", de.Yield(66, GREEN, ARMOUR))
H.isNil("...at Turtle's top end either", de.Yield(99, BLUE, ARMOUR))
H.isNil("a grey yields nothing", de.Yield(40, 0, ARMOUR))
H.isNil("a non-equippable green yields nothing", de.Yield(40, GREEN, "SOUP"))

-- Epics are absent ON PURPOSE: the source data holds nine items with yields
-- no real item produces. An unanswerable epic must stay unanswerable rather
-- than borrow the rare table, which would understate it by a shard tier.
for i = 1, table.getn(ALL_BANDS) do
    H.isNil("epic band " .. ALL_BANDS[i] .. " has no data",
            de.Yield(ALL_BANDS[i], PURPLE, ARMOUR))
end

-- ---------------------------------------------------------------------------
H.section("the shipped ladder -- material tiers climb in the right order")
-- ---------------------------------------------------------------------------

-- These are the tiers vanilla actually uses, and they are the one thing about
-- the generated table worth pinning by hand: a regeneration that shifted every
-- band by one would still sum to 1.0 and still use real reagents.
local GREEN_ARMOUR_DUST = {
    [15] = 10940, [20] = 10940, [25] = 10940,   -- Strange Dust
    [30] = 11083, [35] = 11083,                 -- Soul Dust
    [40] = 11137, [45] = 11137,                 -- Vision Dust
    [50] = 11176, [55] = 11176,                 -- Dream Dust
    [60] = 16204, [65] = 16204,                 -- Illusion Dust
}
local GREEN_WEAPON_ESSENCE = {
    [15] = 10938, [20] = 10939,                 -- Lesser/Greater Magic
    [35] = 11134, [40] = 11135,                 -- Lesser/Greater Mystic
    [45] = 11174, [50] = 11175,                 -- Lesser/Greater Nether
    [55] = 16202, [60] = 16203,                 -- Lesser/Greater Eternal
}
local RARE_SHARD = {
    [20] = 10978, [25] = 10978,                 -- Small Glimmering
    [30] = 11084, [35] = 11138, [40] = 11139,
    [45] = 11177, [50] = 11178, [55] = 14343,
    [60] = 14344, [65] = 14344,                 -- Large Brilliant
}

for band, matId in pairs(GREEN_ARMOUR_DUST) do
    local rows = de.Yield(band, GREEN, ARMOUR)
    H.check("green armour band " .. band .. " is led by "
            .. REAGENT[matId], top(rows) == matId,
            "got " .. tostring(REAGENT[top(rows)]))
end
for band, matId in pairs(GREEN_WEAPON_ESSENCE) do
    local rows = de.Yield(band, GREEN, WEAPON)
    H.check("green weapon band " .. band .. " is led by "
            .. REAGENT[matId], top(rows) == matId,
            "got " .. tostring(REAGENT[top(rows)]))
end
for band, matId in pairs(RARE_SHARD) do
    H.eq("rare band " .. band .. " gives " .. REAGENT[matId],
         top(de.Yield(band, BLUE, ARMOUR)), matId)
end

-- Armour is dust-led, weapons are essence-led. This is the assertion that
-- catches the two halves of the table being exchanged -- which sums to 1.0,
-- uses real reagents and climbs the ladder correctly, so nothing else would.
for band, _ in pairs(GREEN_WEAPON_ESSENCE) do
    local a, w = de.Yield(band, GREEN, ARMOUR), de.Yield(band, GREEN, WEAPON)
    H.check("band " .. band .. ": armour leads with dust",
            DUST[top(a)] == true)
    H.check("band " .. band .. ": weapon does NOT lead with dust",
            DUST[top(w)] == nil)
end

-- Where the source had no usable weapon data the band ships armour only, and
-- must NOT quietly hand back the armour numbers instead.
H.check("a band may answer for armour and not for weapons",
        de.Yield(25, GREEN, ARMOUR) ~= nil
        and de.Yield(25, GREEN, WEAPON) == nil)

-- ---------------------------------------------------------------------------
H.section("the shipped table is internally sound")
-- ---------------------------------------------------------------------------

local checked = 0
local QUALITIES = { GREEN, BLUE, PURPLE }
local SLOTS = { ARMOUR, WEAPON }
for qi = 1, table.getn(QUALITIES) do
    for bi = 1, table.getn(ALL_BANDS) do
        for si = 1, table.getn(SLOTS) do
            local rows = de.Yield(ALL_BANDS[bi], QUALITIES[qi], SLOTS[si])
            if rows then
                checked = checked + 1
                local sum, label = 0, "q" .. QUALITIES[qi] .. " band "
                    .. ALL_BANDS[bi] .. " " .. SLOTS[si]
                for i = 1, table.getn(rows) do
                    local r = rows[i]
                    H.check(label .. ": " .. tostring(r.itemId)
                            .. " is a real reagent", REAGENT[r.itemId] ~= nil)
                    H.check(label .. ": chance is a real probability",
                            r.chance > 0 and r.chance <= 1)
                    H.check(label .. ": mean yield is at least one",
                            r.mean >= 1)
                    sum = sum + r.chance
                end
                H.near(label .. ": chances sum to 1", sum, 1, 0.0005)
            end
        end
    end
end
H.check("the table actually has bands in it -- an empty one would pass"
        .. " every loop above", checked >= 25, "checked " .. checked)

-- A shard is the rare outcome for a green and the only outcome for a blue.
-- Backwards would make every green look like a shard farm.
local greenTop, blueTop = de.Yield(45, GREEN, ARMOUR), de.Yield(45, BLUE, ARMOUR)
H.check("a green's shard is the unlikely branch",
        SHARD[top(greenTop)] == nil)
H.check("a blue IS the shard", SHARD[top(blueTop)] == true)

-- ---------------------------------------------------------------------------
H.section("de.Value -- the expectation is weighted")
-- ---------------------------------------------------------------------------

local function flat(p) return function() return p end end

-- Decomposition: pricing one material at a time and adding up must equal
-- pricing them all at once. This catches a value that forgot to weight by
-- chance WITHOUT restating the generated constants -- de.Yield reports them,
-- de.Value must agree with what it reports.
local rows = de.Yield(45, GREEN, ARMOUR)
local parts = 0
for i = 1, table.getn(rows) do
    local want = rows[i].itemId
    parts = parts + de.Value(45, GREEN, ARMOUR, nil, function(matId)
        if matId == want then return 1000000 end
        return 0
    end)
end
local whole = de.Value(45, GREEN, ARMOUR, nil, flat(1000000))
H.near("the parts add up to the whole", parts, whole, 3)

-- ...and each part is its own chance x mean x price, which is the actual
-- definition of the expectation.
for i = 1, table.getn(rows) do
    local r = rows[i]
    local got = de.Value(45, GREEN, ARMOUR, nil, function(matId)
        if matId == r.itemId then return 1000000 end
        return 0
    end)
    H.near(REAGENT[r.itemId] .. " contributes chance x mean x price",
           got, r.chance * r.mean * 1000000, 2)
end

H.check("doubling every price doubles the value",
        math.abs(de.Value(45, GREEN, ARMOUR, nil, flat(2000))
                 - 2 * de.Value(45, GREEN, ARMOUR, nil, flat(1000))) <= 2)
H.check("value rises with the band",
        de.Value(55, GREEN, ARMOUR, nil, flat(1000))
        > 0 and de.Value(15, GREEN, ARMOUR, nil, flat(1000)) > 0)
H.check("a free material is worth nothing",
        de.Value(45, GREEN, ARMOUR, nil, flat(0)) == 0)

-- ONE unpriced material makes the WHOLE answer unknown. Counting it as zero
-- would under-report every item whose shard has never been seen -- and
-- under-reporting a disenchant value is the direction that loses money.
local shardId = nil
for i = 1, table.getn(rows) do
    if SHARD[rows[i].itemId] then shardId = rows[i].itemId end
end
H.check("the band under test really does have a shard", shardId ~= nil)
H.isNil("one unpriced material makes the whole value unknown",
        de.Value(45, GREEN, ARMOUR, nil, function(matId)
            if matId == shardId then return nil end
            return 1000
        end))
H.isNil("no pricer at all is not a value of zero",
        de.Value(45, GREEN, ARMOUR, nil, nil))
H.isNil("an unanswerable band is not a value of zero",
        de.Value(66, GREEN, ARMOUR, nil, flat(1000)))

-- ---------------------------------------------------------------------------
H.section("de.Yield hands out copies, not the table itself")
-- ---------------------------------------------------------------------------

-- Callers get a fresh list each time. If they got the stored rows, one
-- caller sorting or trimming its result would silently rewrite the shipped
-- constants for every later caller in the session.
--
-- Tested by IDENTITY, not by mutating and re-reading. An implementation that
-- hands back the live rows and re-stamps their fields on every call repairs
-- its own damage between two reads, so the mutation never shows -- it only
-- shows once a caller keeps its list and something else writes to the table
-- meanwhile, which is exactly the bug that would reach a player and not a
-- test. Two calls returning the same object is the thing to refuse.
local one, two = de.Yield(45, GREEN, ARMOUR), de.Yield(45, GREEN, ARMOUR)
H.check("each call builds a fresh list", one ~= two)
H.check("...whose rows are fresh too", one[1] ~= two[1])
H.check("...all of them", one[table.getn(one)] ~= two[table.getn(two)])

-- And with that established, mutating one really is harmless.
one[1].chance, one[1].itemId = 0.5, 1
local three = de.Yield(45, GREEN, ARMOUR)
H.neq("mutating a yield does not corrupt the table", three[1].itemId, 1)
H.check("...nor its probabilities", three[1].chance ~= 0.5)

-- ---------------------------------------------------------------------------
H.section("de.ItemLevel -- the shipped lookup, and its absence")
-- ---------------------------------------------------------------------------

-- core/itemlevel.lua ships EMPTY on purpose: ShaguScore, the obvious source,
-- carries no licence at all. The point of these is that an absent table is a
-- clean "I do not know", never a zero and never an error.
H.isNil("an unknown item has no level", de.ItemLevel(12345))
H.isNil("a nil id has no level", de.ItemLevel(nil))

local saved = A.ilvlData
A.ilvlData = { [777] = 42, [778] = 0, [779] = "forty" }
local lvl, src = de.ItemLevel(777)
H.eq("a populated table answers", lvl, 42)
H.eq("...and says where the answer came from", src, "itemlevel")
H.isNil("a zero level is not a level", de.ItemLevel(778))
H.isNil("a non-numeric level is not a level", de.ItemLevel(779))
H.isNil("an id the table lacks is still unknown", de.ItemLevel(780))
A.ilvlData = saved

-- ---------------------------------------------------------------------------
H.section("de.Resolve -- one item id, everything the rule needs")
-- ---------------------------------------------------------------------------

W.FireAddonLoaded(A)

-- A green chest the client knows about, with an item level the table knows.
W.AddItem(900, { name = "Test Chest", quality = GREEN, equipLoc = "INVTYPE_CHEST" })
W.AddItem(901, { name = "Test Sword", quality = GREEN, equipLoc = "INVTYPE_2HWEAPON" })
W.AddItem(902, { name = "Test Cloth", quality = 1,     equipLoc = "" })
W.AddItem(903, { name = "Uncached Level", quality = GREEN, equipLoc = "INVTYPE_CHEST" })
W.AddItem(11176, { name = "Dream Dust" })
W.AddItem(11175, { name = "Greater Nether Essence" })
W.AddItem(11178, { name = "Large Radiant Shard" })

local savedIlvl = A.ilvlData
A.ilvlData = { [900] = 48, [901] = 48, [902] = 48 }

local lvl, src, q, slot = de.Resolve(900)
H.eq("resolves the item level", lvl, 48)
H.eq("...and says where from", src, "itemlevel")
H.eq("...and the quality", q, GREEN)
H.eq("...and the equip slot", slot, "INVTYPE_CHEST")

H.isNil("a white shirt resolves to nothing", de.Resolve(902))
H.isNil("an item with no shipped level resolves to nothing", de.Resolve(903))
H.isNil("an item the client has never cached resolves to nothing",
        de.Resolve(99999))
H.isNil("a nil id resolves to nothing", de.Resolve(nil))

-- ---------------------------------------------------------------------------
H.section("de.YieldOf / de.ValueOf -- the entry points the UI uses")
-- ---------------------------------------------------------------------------

local byId = de.YieldOf(900)
local direct = de.Yield(48, GREEN, "INVTYPE_CHEST", 900)
H.check("YieldOf agrees with the rule it wraps",
        byId ~= nil and direct ~= nil and top(byId) == top(direct))
H.eq("...same number of materials", table.getn(byId), table.getn(direct))
H.isNil("YieldOf says nothing for an unresolvable item", de.YieldOf(903))

local flatPricer = function() return 1000 end
local vById, vSrc = de.ValueOf(900, flatPricer)
H.eq("ValueOf agrees with the rule it wraps", vById,
     de.Value(48, GREEN, "INVTYPE_CHEST", 900, flatPricer))
H.eq("...and passes the source through", vSrc, "itemlevel")
H.isNil("ValueOf says nothing for an unresolvable item",
        de.ValueOf(903, flatPricer))
H.isNil("ValueOf says nothing without a pricer", de.ValueOf(900, nil))

-- Armour and weapon of the SAME level must not come back identical -- that is
-- the wiring mistake that would make the equip slot decorative.
H.check("armour and weapon differ at the same item level",
        top(de.YieldOf(900)) ~= top(de.YieldOf(901)))

-- ---------------------------------------------------------------------------
H.section("de.MarketPrice -- one pricer, so two callers cannot disagree")
-- ---------------------------------------------------------------------------

A.db.RecordAuction(11176, 5000, "Dream Dust")
H.check("a recorded auction gives a price", de.MarketPrice(11176) ~= nil)
H.isNil("an unseen material has no price", de.MarketPrice(987654))

-- ---------------------------------------------------------------------------
H.section("de.BreakdownText")
-- ---------------------------------------------------------------------------

local rows48 = de.Yield(48, GREEN, "INVTYPE_CHEST")
local text = de.BreakdownText(rows48, function(matId)
    return REAGENT[matId]
end)
H.eq("one line per material", table.getn(text), table.getn(rows48))
H.check("a line carries its percentage",
        string.find(text[1], "%%") ~= nil, text[1])
H.check("a line carries its material name",
        string.find(text[1], REAGENT[rows48[1].itemId], 1, true) ~= nil,
        text[1])
H.check("the leading line is the likeliest one",
        string.find(text[1], REAGENT[top(rows48)], 1, true) ~= nil)

-- Percentages are rounded, not truncated: 4.7% reading as "4%" understates
-- every shard line, and the shard is the part people care about.
local rounded = de.BreakdownText(
    { { itemId = 11176, chance = 0.047, mean = 1 } },
    function() return "Dream Dust" end)
H.check("percentages round rather than truncate",
        string.find(rounded[1], "5%%") ~= nil, rounded[1])

-- An unnamed material must still print something identifiable rather than
-- "nil" or an empty gap -- the client simply has not cached it yet.
local unnamed = de.BreakdownText(rows48, function() return nil end)
H.check("an unnamed material falls back to its id",
        string.find(unnamed[1], "item:", 1, true) ~= nil, unnamed[1])
H.isNil("no rows means no text", de.BreakdownText(nil, function() return "x" end))

A.ilvlData = savedIlvl

os.exit(H.report("disenchant"))
