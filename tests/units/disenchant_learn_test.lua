-- Aegis: Exchange -- tests/units/disenchant_learn_test.lua
--
-- Learning what an item disenchants into by watching the player do it.
--
-- THE PROBLEM THIS SOLVES. 1.12 never reports "you disenchanted X". A spell is
-- cast and a bag item is clicked, and neither step names the item, so the only
-- handle is the click itself. Everything here is about attributing a loot
-- window to that click WITHOUT being fooled by the other things a click on a
-- bag item can mean.
--
-- WHY THAT MATTERS MORE THAN USUAL. A wrong attribution does not show up as an
-- error; it writes a false observation into a saved variable that outranks the
-- shipped table forever afterwards. There is no way to tell a bad record from
-- a good one later, so the tests that matter most here are the ones where
-- NOTHING should be written.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)
local de, db = A.de, A.db

local GREEN = 2

-- ilvl 48 -> band 50, whose materials are Dream Dust, Greater Nether Essence
-- and Large Radiant Shard.
local DUST, ESSENCE, SHARD = 11176, 11175, 11178
local CHEST = "|cff1eff00|Hitem:900:0:0:0|h[Test Chest]|h|r"
local BOX   = "|cffffffff|Hitem:910:0:0:0|h[Lockbox]|h|r"

W.AddItem(900, { name = "Test Chest", quality = GREEN,
                 equipLoc = "INVTYPE_CHEST" })
W.AddItem(910, { name = "Lockbox", quality = 1, equipLoc = "" })
W.AddItem(DUST,    { name = "Dream Dust" })
W.AddItem(ESSENCE, { name = "Greater Nether Essence" })
W.AddItem(SHARD,   { name = "Large Radiant Shard" })
W.AddItem(858,     { name = "Healing Potion" })

local function freshBags(link)
    W.SetBags({ [0] = { { link = link or CHEST, count = 1 }, {}, {}, {} } })
end

-- One complete disenchant: a spell is waiting for a target, the player clicks
-- the item, the loot window opens.
local function disenchant(loot, targeting, link)
    freshBags(link)
    W.spellTargeting = (targeting ~= false)
    PickupContainerItem(0, 1)
    W.spellTargeting = false
    W.SetLoot(loot)
    W.FireEvent(A.frame, "LOOT_OPENED")
end

local function seenCount(itemId, matId)
    local rec = db.Disenchants(itemId)
    if not rec or not rec[matId] then return 0 end
    return rec[matId].n
end

local function totalRecords(itemId)
    local rec, n = db.Disenchants(itemId), 0
    if rec then for _ in pairs(rec) do n = n + 1 end end
    return n
end

-- ---------------------------------------------------------------------------
H.section("the happy path")
-- ---------------------------------------------------------------------------

disenchant({ { link = W.items[DUST].link, quantity = 2 } })
H.eq("one disenchant is recorded once", seenCount(900, DUST), 1)
local rec = db.Disenchants(900)
H.eq("...with the quantity it produced", rec[DUST].total, 2)

disenchant({ { link = W.items[DUST].link, quantity = 3 } })
H.eq("a second adds to the count", seenCount(900, DUST), 2)
H.eq("...and to the total", db.Disenchants(900)[DUST].total, 5)

-- ---------------------------------------------------------------------------
H.section("everything that must NOT be recorded")
-- ---------------------------------------------------------------------------

local before = seenCount(900, DUST)

-- A bag click with no spell waiting is just a bag click. This is the ordinary
-- case -- every time anyone moves an item -- so if it recorded anything the DB
-- would fill with nonsense within a minute of playing.
disenchant({ { link = W.items[DUST].link, quantity = 2 } }, false)
H.eq("a plain bag click records nothing", seenCount(900, DUST), before)

-- A lockbox is not disenchantable. Without this check, picking a shard out of
-- a lockbox would teach us that lockboxes disenchant into shards -- and the
-- item clicked while Pick Lock was targeting is exactly the lockbox.
disenchant({ { link = W.items[SHARD].link, quantity = 1 } }, true, BOX)
H.eq("a lockbox learns nothing", totalRecords(910), 0)

-- Loot that is not entirely enchanting reagents did not come from a
-- disenchant. This is the discriminator that lets the whole thing work
-- without reading a localised spell name.
disenchant({ { link = W.items[DUST].link, quantity = 2 },
             { link = W.items[858].link,  quantity = 1 } })
H.eq("loot with a non-reagent in it records nothing",
     seenCount(900, DUST), before)

-- ...and nothing partial was written before the bad slot was reached.
H.eq("...not even the reagent that came first", db.Disenchants(900)[DUST].total, 5)

disenchant({ { money = true, quantity = 1 } })
H.eq("a money-only loot window records nothing", seenCount(900, DUST), before)

disenchant({})
H.eq("an empty loot window records nothing", seenCount(900, DUST), before)

-- Loot that arrives much later is a different event entirely.
freshBags()
W.spellTargeting = true
PickupContainerItem(0, 1)
W.spellTargeting = false
W.Advance(60)
W.SetLoot({ { link = W.items[DUST].link, quantity = 2 } })
W.FireEvent(A.frame, "LOOT_OPENED")
H.eq("loot a minute later is not this disenchant", seenCount(900, DUST), before)

-- A cast that failed disenchanted nothing.
freshBags()
W.spellTargeting = true
PickupContainerItem(0, 1)
W.spellTargeting = false
W.FireEvent(A.frame, "SPELLCAST_FAILED")
W.SetLoot({ { link = W.items[DUST].link, quantity = 2 } })
W.FireEvent(A.frame, "LOOT_OPENED")
H.eq("an interrupted cast records nothing", seenCount(900, DUST), before)

-- One loot window, one record. A second LOOT_OPENED for the same loot -- the
-- client fires it more than once -- must not count the same break twice.
disenchant({ { link = W.items[DUST].link, quantity = 2 } })
local afterOne = seenCount(900, DUST)
W.FireEvent(A.frame, "LOOT_OPENED")
W.FireEvent(A.frame, "LOOT_OPENED")
H.eq("a repeated LOOT_OPENED does not double-count",
     seenCount(900, DUST), afterOne)

-- ---------------------------------------------------------------------------
H.section("posting an auction is not a disenchant")
-- ---------------------------------------------------------------------------

-- sell.PlaceFromBag calls PickupContainerItem itself, so the hook sees our own
-- calls. No spell is targeting during a post, so nothing should arm -- but
-- this is exactly the kind of cross-feature interaction that bites a year
-- later, so it is pinned rather than reasoned about.
local mark = seenCount(900, DUST)
freshBags()
A.sell.PlaceFromBag(0, 1)
W.SetLoot({ { link = W.items[DUST].link, quantity = 2 } })
W.FireEvent(A.frame, "LOOT_OPENED")
H.eq("placing an item for auction records nothing",
     seenCount(900, DUST), mark)

-- ---------------------------------------------------------------------------
H.section("materials seen -> which band the item is in")
-- ---------------------------------------------------------------------------

-- A DUST does not name a band on its own: Dream Dust belongs to bands 50 and
-- 55, whose yields differ by more than double. Answering on one observation
-- would be a coin flip dressed as a measurement.
local band, count = de.BandCandidates(GREEN, { [DUST] = true })
H.eq("a dust leaves more than one band open", count > 1, true)
H.eq("...and offers the lowest of them", band, 50)

-- An ESSENCE does. 24 of the 36 material/quality combinations do.
band, count = de.BandCandidates(GREEN, { [ESSENCE] = true })
H.eq("an essence names its band outright", count, 1)
H.eq("...which is band 50", band, 50)

-- Evidence narrows: dust + essence is only consistent with one band.
band, count = de.BandCandidates(GREEN, { [DUST] = true, [ESSENCE] = true })
H.eq("two materials together narrow it to one", count, 1)
H.eq("...band 50", band, 50)

-- Materials that cannot come from the same band mean something is wrong, and
-- guessing which one to believe is worse than declining.
band, count = de.BandCandidates(GREEN, { [10940] = true, [16204] = true })
H.eq("contradictory materials leave no band", count, 0)
H.isNil("...and no answer", band)

H.eq("no materials, no candidates",
     select(2, de.BandCandidates(GREEN, {})), 0)
H.isNil("a nil quality gives nothing", de.BandCandidates(nil, { [DUST] = true }))

-- ---------------------------------------------------------------------------
H.section("quantities separate what materials cannot")
-- ---------------------------------------------------------------------------

-- WHY THIS EXISTS. Green bands 60 and 65 yield EXACTLY the same three
-- materials, so a player's own disenchants could never tell them apart -- and
-- before v1.54.13 the table was missing band 65's shard, so a Large Brilliant
-- Shard pinned band 60 and an item level 62 green was valued on half the dust.
-- The counts separate them: band 60 rolls Illusion Dust 1-2 and Greater
-- Eternal Essence 1-2; band 65 rolls dust 2-5 and essence always 2.
local IDUST, GEE, LBS = 16204, 16203, 14344
local function obs(n, total) return { n = n, total = total } end

-- Materials alone: still two bands, and that is the honest answer.
band, count = de.BandCandidates(GREEN, { [IDUST] = true, [GEE] = true,
                                         [LBS] = true })
H.eq("materials alone cannot separate green 60 from 65", count, 2)

-- A SINGLE Illusion Dust is impossible in band 65.
band, count = de.BandCandidates(GREEN, { [IDUST] = obs(1, 1) })
H.eq("one Illusion Dust names band 60", count, 1)
H.eq("...which is 60", band, 60)

-- THREE of them are impossible in band 60.
band, count = de.BandCandidates(GREEN, { [IDUST] = obs(1, 3) })
H.eq("three Illusion Dust name band 65", count, 1)
H.eq("...which is 65", band, 65)

-- Two is what both roll, so it proves nothing.
band, count = de.BandCandidates(GREEN, { [IDUST] = obs(1, 2) })
H.eq("two Illusion Dust leave both open", count, 2)

-- The essence separates them too: band 65 ALWAYS gives two.
band, count = de.BandCandidates(GREEN, { [GEE] = obs(1, 1) })
H.eq("a single Greater Eternal Essence names band 60", band, 60)
H.eq("...alone", count, 1)
band, count = de.BandCandidates(GREEN, { [GEE] = obs(1, 2) })
H.eq("two of them leave both open", count, 2)

-- THE TEST IS EXACT, AND BOTH ENDS ARE INCLUSIVE. n rolls between min and max
-- can sum to `total` if and only if n*min <= total <= n*max.
--   3 breaks, 6 dust:  2+2+2 -- both bands can do it.
band, count = de.BandCandidates(GREEN, { [IDUST] = obs(3, 6) })
H.eq("six dust over three breaks fits both (2+2+2)", count, 2)
--   3 breaks, 5 dust:  needs a 1 somewhere -- only band 60 rolls a 1.
band, count = de.BandCandidates(GREEN, { [IDUST] = obs(3, 5) })
H.eq("five dust over three breaks can only be band 60", band, 60)
H.eq("...alone", count, 1)
--   3 breaks, 7 dust:  needs a 3 somewhere -- only band 65 rolls a 3.
band, count = de.BandCandidates(GREEN, { [IDUST] = obs(3, 7) })
H.eq("seven dust over three breaks can only be band 65", band, 65)
H.eq("...alone", count, 1)

-- NOT AN AVERAGE. A mean-based test would put 1.67 per break "closer to 60"
-- and 2.33 "closer to 65" and call both -- but the question is which band
-- COULD have produced the rolls, and that is a yes/no.

-- QUANTITIES MAY NARROW, NEVER ERASE. A server that rolls different counts
-- from the 1.12.1 table -- Turtle changes things -- must not turn material
-- evidence into no evidence. Strange Dust belongs to bands 15, 20 and 25 and
-- tops out at six; nine of it contradicts all three, so the answer falls back
-- to what the material alone says.
band, count = de.BandCandidates(GREEN, { [10940] = obs(1, 9) })
H.eq("counts that fit no band leave the material answer standing", count, 3)
H.eq("...its lowest band", band, 15)

-- ...and the same where the materials had already pinned a band: an essence
-- names its band outright, and an out-of-range count must not unpin it.
band, count = de.BandCandidates(GREEN, { [ESSENCE] = obs(1, 9) })
H.eq("an out-of-range count cannot unpin an essence", count, 1)
H.eq("...still band 50", band, 50)

-- A malformed record is presence, not a contradiction.
band, count = de.BandCandidates(GREEN, { [IDUST] = { n = 0, total = 0 } })
H.eq("a record with no procs counts as presence only", count, 2)

-- ...AND THE REAL PATH PASSES THE COUNTS. db.RecordDisenchant stores n and
-- total per material; if de.BandFromObservation flattened that back to
-- `true`, everything above would be tested and none of it used.
W.AddItem(970, { name = "Nightshade Leggings", quality = GREEN,
                 equipLoc = "INVTYPE_LEGS" })
db.RecordDisenchant(970, IDUST, 4)
band, count = de.BandFromObservation(970, GREEN)
H.eq("a stored disenchant of four dust reads as band 65", band, 65)
H.eq("...unambiguously", count, 1)
local lvl2, src2 = de.ItemLevel(970, GREEN)
H.eq("...and the item's level is taken from it", lvl2, 65)
H.eq("...as an observation", src2, "observed")

-- THE REPORTED CASE, and the one that used to go wrong: a Large Brilliant
-- Shard on its own. Both bands drop one, one at a time, so it must NOT pin.
W.AddItem(971, { name = "Shard Only Green", quality = GREEN,
                 equipLoc = "INVTYPE_LEGS" })
db.RecordDisenchant(971, LBS, 1)
band, count = de.BandFromObservation(971, GREEN)
H.eq("a lone Large Brilliant Shard still leaves both bands open", count, 2)

-- ---------------------------------------------------------------------------
H.section("what is observed outranks what the client says")
-- ---------------------------------------------------------------------------

-- The client's item level is the item's own data. What the player SAW is
-- evidence from the server they are on -- and Turtle can change what an item
-- breaks into without changing its level -- so observation wins.
W.AddItem(950, { name = "Odd Chest", quality = GREEN,
                 equipLoc = "INVTYPE_CHEST", itemLevel = 22 })
W.SetClientItemData(true)

-- Only the dust so far, so the evidence is ambiguous -- and an ambiguous
-- observation must NOT displace a real answer, nor be believed itself.
db.RecordDisenchant(950, DUST, 2)
local lvl, src = de.ItemLevel(950, GREEN)
H.eq("an ambiguous observation falls back to the client", lvl, 22)
H.eq("...and says so", src, "client")

db.RecordDisenchant(950, ESSENCE, 1)
lvl, src = de.ItemLevel(950, GREEN)
H.eq("once the evidence is unambiguous it wins", lvl, 50)
H.eq("...and says where from", src, "observed")

-- Without a quality there is nothing to match materials against, so the
-- client's number is all that is left.
lvl, src = de.ItemLevel(950)
H.eq("no quality means no inference", src, "client")

-- An item nothing can answer for: no client data, never disenchanted. There
-- is no shipped table underneath any more, so the answer is nothing.
W.AddItem(60001, { name = "Turtle Thing", quality = GREEN,
                   equipLoc = "INVTYPE_CHEST" })
H.isNil("an item with neither source is unanswerable",
        de.ItemLevel(60001, GREEN))
db.RecordDisenchant(60001, ESSENCE, 1)
lvl, src = de.ItemLevel(60001, GREEN)
H.eq("one disenchant makes it answerable", lvl, 50)
H.eq("...from observation alone", src, "observed")
H.check("...and it now has a value",
        de.ValueOf(60001, function() return 1000 end) ~= nil)

W.SetClientItemData(false)

-- ---------------------------------------------------------------------------
H.section("only observations are persisted")
-- ---------------------------------------------------------------------------

-- Nothing derived may reach the saved variable. A band or an item level
-- written beside real counts becomes indistinguishable from evidence later,
-- and there is no way back from that.
local stored = db.Disenchants(900)
local strayField = nil
for key, value in pairs(stored) do
    if type(key) ~= "number" then strayField = tostring(key) end
    if type(value) ~= "table" or value.n == nil or value.total == nil then
        strayField = tostring(key)
    end
end
H.isNil("the store holds material counts and nothing else", strayField)

os.exit(H.report("disenchant.learn"))
