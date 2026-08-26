-- Aegis: Exchange -- tests/units/tooltip_test.lua
--
-- The lines Aegis adds to a GameTooltip.
--
-- WHY THIS EXISTS AT ALL. Tooltip code is easy to leave untested because it
-- "just draws" -- but what it draws is a set of DECISIONS: which lines appear,
-- whether a per-item number gets multiplied by a stack count, and when the
-- addon should say nothing rather than say "unknown". Those are all wrong-able
-- without anything erroring, and every one of them is visible to a player on
-- every item they hover.
--
-- The tooltip itself is a capture table rather than a frame. Nothing here
-- checks how the lines LOOK -- fonts, colour, wrapping and placement are not
-- testable from a terminal and are deliberately not faked into looking so.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.LoadUI("tooltip")
W.FireAddonLoaded(A)

local GREEN = 2

-- A tooltip that records instead of drawing.
local function Capture()
    local t = { lines = {}, shown = 0 }
    function t:AddDoubleLine(left, right)
        table.insert(self.lines, { left = left, right = right })
    end
    function t:AddLine(text)
        table.insert(self.lines, { left = text })
    end
    function t:Show() self.shown = self.shown + 1 end
    return t
end

-- The disenchant label carries its verdict and provenance inside it
-- ("Disenchant (worth more than vendor):"), so an exact match on the bare word
-- would only ever pass on the one case with neither. Prefix instead -- and
-- REQUIRE A VALUE, because "Disenchants Into:" shares the prefix and is a
-- heading with nothing on the right. Matching it and then reading .right is a
-- nil, which is how this helper failed the first time.
local function valueLinePrefixed(t, prefix)
    for i = 1, table.getn(t.lines) do
        local L = t.lines[i].left or ""
        if t.lines[i].right
            and string.sub(L, 1, string.len(prefix)) == prefix then
            return t.lines[i]
        end
    end
    return nil
end

local function lineFor(t, label)
    for i = 1, table.getn(t.lines) do
        if t.lines[i].left == label then return t.lines[i] end
    end
    return nil
end

-- A BREAKDOWN row specifically -- "78%  Dream Dust  x1.5" -- not merely a line
-- that mentions a material. The diagnosis line names a material too ("no price
-- yet for Dream Dust"), and matching on the name alone caught that instead,
-- which made a test of the breakdown pass on a line that is not one.
local function breakdownLineFor(t, needle)
    for i = 1, table.getn(t.lines) do
        local L = t.lines[i].left or ""
        if string.find(L, "%d+%%") and string.find(L, needle, 1, true) then
            return t.lines[i]
        end
    end
    return nil
end

local function anyLineWith(t, needle)
    for i = 1, table.getn(t.lines) do
        if string.find(t.lines[i].left or "", needle, 1, true) then
            return t.lines[i]
        end
    end
    return nil
end

-- A green chest whose item level the shipped table knows, and priced
-- materials so the value can actually be computed.
W.AddItem(900, { name = "Test Chest", quality = GREEN,
                 equipLoc = "INVTYPE_CHEST", itemLevel = 48,
                 type = "Armor", subType = "Cloth" })
W.AddItem(11176, { name = "Dream Dust", quality = 1 })
W.AddItem(11175, { name = "Greater Nether Essence", quality = 1 })
W.AddItem(11178, { name = "Large Radiant Shard", quality = 3 })
W.SetClientItemData(true)
A.db.RecordAuction(11176, 5000, "Dream Dust")
A.db.RecordAuction(11175, 20000, "Greater Nether Essence")
A.db.RecordAuction(11178, 300000, "Large Radiant Shard")

local shiftHeld = false
function IsShiftKeyDown() return shiftHeld end

-- ---------------------------------------------------------------------------
H.section("the disenchant line appears, and says one item's worth")
-- ---------------------------------------------------------------------------

local t = Capture()
A.tooltip.Extend(t, 900, 1)
local line = valueLinePrefixed(t, "Disenchant")
H.check("a disenchantable item gets the line", line ~= nil)
H.check("the tooltip was re-flowed", t.shown > 0)

-- A disenchant value is PER ITEM. Each break rolls the table again, so a
-- stack of twenty is twenty separate draws -- not twenty times this number.
-- The price lines beside it DO multiply, which is exactly why this is easy to
-- get wrong: the obvious edit is to route it through the same helper.
local single = Capture()
A.tooltip.Extend(single, 900, 1)
local stacked = Capture()
A.tooltip.Extend(stacked, 900, 20)
H.eq("a stack of twenty does not multiply the disenchant value",
     valueLinePrefixed(stacked, "Disenchant").right,
     valueLinePrefixed(single, "Disenchant").right)
H.check("...and no stack total is appended to it",
        string.find(valueLinePrefixed(stacked, "Disenchant").right, "x20", 1, true)
        == nil, valueLinePrefixed(stacked, "Disenchant").right)

-- ---------------------------------------------------------------------------
H.section("silence, where silence is right")
-- ---------------------------------------------------------------------------

-- Nothing the rule cannot answer for gets a line. An "unknown" row on every
-- grey, every trade good and every uncached item would be noise on hundreds
-- of items to be informative about a handful.
W.AddItem(902, { name = "Test Cloth", quality = 1, equipLoc = "" })
local cloth = Capture()
A.tooltip.Extend(cloth, 902, 5)
H.isNil("a trade good gets no disenchant line",
        valueLinePrefixed(cloth, "Disenchant"))

-- Cached, disenchantable, and the client has no level for it: the state of
-- every item on a client with no mod exposing one.
W.AddItem(903, { name = "Unknown Level", quality = GREEN,
                 equipLoc = "INVTYPE_CHEST" })
local noLevel = Capture()
A.tooltip.Extend(noLevel, 903, 1)
H.isNil("an item whose level no source knows gets no line",
        valueLinePrefixed(noLevel, "Disenchant"))
H.isNil("...and no 'unknown' text either", anyLineWith(noLevel, "unknown"))

-- ---------------------------------------------------------------------------
H.section("the per-line setting")
-- ---------------------------------------------------------------------------

A.db.SetSetting("tipDisenchant", false)
local off = Capture()
A.tooltip.Extend(off, 900, 1)
H.isNil("switched off, the line is gone", valueLinePrefixed(off, "Disenchant"))
A.db.SetSetting("tipDisenchant", true)
H.check("switched back on, it returns",
        valueLinePrefixed((function() local c = Capture()
                 A.tooltip.Extend(c, 900, 1); return c end)(),
                "Disenchant") ~= nil)

A.db.SetSetting("tooltip", false)
local master = Capture()
A.tooltip.Extend(master, 900, 1)
H.eq("the master switch silences it too", table.getn(master.lines), 0)
A.db.SetSetting("tooltip", true)

-- ---------------------------------------------------------------------------
H.section("the breakdown, on by default and gated when turned off")
-- ---------------------------------------------------------------------------

-- ON BY DEFAULT, and that default is the point. The split is a fact about the
-- ITEM -- required level gives the band, the band gives the probabilities --
-- and it needs no market data at all, so it is exactly what is left to show
-- when the VALUE cannot be computed. It was off, which meant the common case
-- showed a bare "?" while the one thing Aegis knew sat behind a checkbox.

shiftHeld = false
local onByDefault = Capture()
A.tooltip.Extend(onByDefault, 900, 1)
H.check("the breakdown shows with no Shift and no setting touched",
        anyLineWith(onByDefault, "Dream Dust") ~= nil)
H.check("...with a percentage", anyLineWith(onByDefault, "%") ~= nil)
H.check("...alongside the value rather than replacing it",
        valueLinePrefixed(onByDefault, "Disenchant") ~= nil)

-- Turned off, it goes -- and Shift still brings it back, so the checkbox
-- never takes away the gesture.
A.db.SetSetting("tipDisenchantRows", false)
local plain = Capture()
A.tooltip.Extend(plain, 900, 1)
H.isNil("turned off, there is no breakdown",
        anyLineWith(plain, "Dream Dust"))
H.check("...and it is fewer lines, not the same ones",
        table.getn(plain.lines) < table.getn(onByDefault.lines))

shiftHeld = true
local expanded = Capture()
A.tooltip.Extend(expanded, 900, 1)
H.check("Shift shows it whatever the setting says",
        anyLineWith(expanded, "Dream Dust") ~= nil)
shiftHeld = false
A.db.SetSetting("tipDisenchantRows", true)

-- ---------------------------------------------------------------------------
H.section("it does not disturb the price lines it sits with")
-- ---------------------------------------------------------------------------

A.db.RecordAuction(900, 12345, "Test Chest")
local both = Capture()
A.tooltip.Extend(both, 900, 4)
H.check("the market line is still there", lineFor(both, "Aegis Market:") ~= nil)
H.check("...and still multiplies by the stack",
        string.find(lineFor(both, "Aegis Market:").right, "x4", 1, true) ~= nil,
        lineFor(both, "Aegis Market:").right)

-- ---------------------------------------------------------------------------
H.section("an approximated level is LABELLED as one")
-- ---------------------------------------------------------------------------

-- WHY THIS EXISTS. Without a client mod the item level is inferred from the
-- level needed to equip the item, which can land a band out -- and adjacent
-- bands differ by more than double in yield. The number is worth showing; it
-- is not worth showing as though it were measured.
--
-- Nothing about the VALUE changes when the label is dropped, which is what
-- makes this the kind of regression only a test catches. The line still
-- appears, still holds money, and still looks right.

-- Required level 45 lands in band 50, whose materials are the three priced at
-- the top of this file -- so the value actually computes rather than going
-- silent for an unrelated reason.
W.AddItem(904, { name = "Approx Chest", quality = GREEN,
                 equipLoc = "INVTYPE_CHEST", minLevel = 45 })

local approx = Capture()
A.tooltip.Extend(approx, 904, 1)
H.check("an item known only by its required level still gets a line",
        valueLinePrefixed(approx, "Disenchant") ~= nil)
H.check("...and the provenance is stated in words",
        anyLineWith(approx, "approx, from required level") ~= nil)

-- The converse, so the label cannot simply be hardcoded on: item 900's level
-- comes from the client, and that answer is exact.
local exact = Capture()
A.tooltip.Extend(exact, 900, 1)
H.check("a client-measured level keeps the plain label",
        valueLinePrefixed(exact, "Disenchant") ~= nil)
H.isNil("...and is never marked approximate",
        anyLineWith(exact, "approx"))

-- ---------------------------------------------------------------------------
H.section("confidence comes before the figures, not appended to one")
-- ---------------------------------------------------------------------------

-- A median resting on one auction and one resting on thirty produce the same
-- figure and are not the same claim. That used to ride as a suffix on the
-- market value; it is now its own line ABOVE the group, because it qualifies
-- every number below it rather than any single one.
local q = Capture()
A.tooltip.Extend(q, 900, 1)
H.check("the sighting count leads",
        anyLineWith(q, "times at auction total") ~= nil)

-- ORDER. Buyout above Market: today's cheapest is what a buyer acts on, and
-- the median is context for it rather than the other way round.
local iBuy, iMkt
for i = 1, table.getn(q.lines) do
    if q.lines[i].left == "Aegis Buyout:" then iBuy = i end
    if q.lines[i].left == "Aegis Market:" then iMkt = i end
end
H.check("both price lines are present", iBuy ~= nil and iMkt ~= nil)
H.check("...buyout above market", iBuy and iMkt and iBuy < iMkt)

-- GROUPS. Auction house, then vendor, then disenchant -- separated by blank
-- lines. An empty string collapses to nothing on 1.12, so the separator has to
-- be a space; a test that accepts either would pass on a tooltip with no gaps.
local blanks = 0
for i = 1, table.getn(q.lines) do
    if q.lines[i].left == " " then blanks = blanks + 1 end
end
H.check("the groups are separated", blanks >= 2, "got " .. blanks)

-- The item class frames the split: armour and weapons break into different
-- things, so it is part of reading the breakdown rather than trivia.
-- Class is a plain LEFT line, not a label/value pair: a double line reserves
-- the right column whether or not anything sits in it, and the label then
-- reads as half a pair with a missing value rather than as a statement.
H.check("the class is shown, hard left",
        anyLineWith(q, "Class: Armor") ~= nil)

-- ---------------------------------------------------------------------------
H.section("the verdict, and only when there is one")
-- ---------------------------------------------------------------------------

-- The number alone still leaves the reader doing the comparison that made them
-- hover. Item 900's materials are priced high above its (unset) market price.
H.check("a clearly-better disenchant says so",
        anyLineWith(q, "worth more than") ~= nil)

-- ...and the reverse. An item listing far above what it breaks for should say
-- that instead, or the line only ever gives one kind of advice.
-- A FRESH id: db.RecordAuction keeps the day's MINIMUM, so a high price
-- written over an item something earlier in this file already recorded
-- cheaply is silently discarded -- and the test then passes or fails on
-- whatever that earlier price happened to be.
W.AddItem(906, { name = "Pricey Chest", quality = GREEN,
                 equipLoc = "INVTYPE_CHEST", itemLevel = 48 })
A.db.RecordAuction(906, 99999999, "Pricey Chest")
local pricey = Capture()
A.tooltip.Extend(pricey, 906, 1)
H.check("an item worth more sold than broken says THAT",
        anyLineWith(pricey, "sells for more") ~= nil)
H.isNil("...and does not also claim the opposite",
        anyLineWith(pricey, "worth more than the AH"))

-- ---------------------------------------------------------------------------
H.section("a value that cannot resolve says WHY")
-- ---------------------------------------------------------------------------

-- THE DEVOUT BELT CASE. de.Value is all-or-nothing: one unpriced material and
-- the whole figure disappears. That is right for the number and useless as an
-- explanation -- aux does the same, and the visible result is a tooltip that
-- says nothing about an item you have scanned repeatedly, with no way to tell
-- whether the rule failed or one shard has simply never been listed.
--
-- Band 50 needs Dream Dust, Greater Nether Essence and Large Radiant Shard.
-- This item's level is known; the market's knowledge of one material is not.
W.AddItem(905, { name = "Unpriced Chest", quality = GREEN,
                 equipLoc = "INVTYPE_CHEST", itemLevel = 48 })
W.AddItem(11999, { name = "Never Listed Shard" })

local before = A.db.MarketValue(11178)
A.db.account.realms = {}            -- forget every market price
A.db.Init()

local blind = Capture()
A.tooltip.Extend(blind, 905, 1)
H.check("the line appears rather than vanishing",
        valueLinePrefixed(blind, "Disenchant") ~= nil)
H.check("...and names a material it has no price for",
        anyLineWith(blind, "no price yet for") ~= nil
        or anyLineWith(blind, "never seen on the AH") ~= nil)

-- ---------------------------------------------------------------------------
H.section("the breakdown is gated two ways")
-- ---------------------------------------------------------------------------

-- Three extra lines on every disenchantable item is a lot of tooltip, so the
-- breakdown is off unless asked for -- by the setting, or by Shift, and the
-- two are independent. A change that collapses them into one takes away either
-- the checkbox or the gesture.
shiftHeld = false
A.db.SetSetting("tipDisenchantRows", false)
local quiet = Capture()
A.tooltip.Extend(quiet, 900, 1)
H.isNil("off and no Shift: no breakdown", breakdownLineFor(quiet, "Dream Dust"))

A.db.SetSetting("tipDisenchantRows", true)
local always = Capture()
A.tooltip.Extend(always, 900, 1)
H.check("the setting alone shows it", breakdownLineFor(always, "Dream Dust") ~= nil)

A.db.SetSetting("tipDisenchantRows", false)
shiftHeld = true
local shifted = Capture()
A.tooltip.Extend(shifted, 900, 1)
H.check("Shift alone still shows it, whatever the setting says",
        breakdownLineFor(shifted, "Dream Dust") ~= nil)
shiftHeld = false

-- ---------------------------------------------------------------------------
H.section("the diagnosis costs nothing extra")
-- ---------------------------------------------------------------------------

-- de.ValueOf hands back WHY it failed alongside the failure. Asking separately
-- resolves the item a second time, and the unpriced path is the common one
-- before a scan -- so the naive version made the most frequent case the most
-- expensive.
W.itemInfoCalls = 0
local cheap = Capture()
A.tooltip.Extend(cheap, 905, 1)
H.check("an unresolvable value still costs one item lookup, not two",
        W.itemInfoCalls <= 2, "got " .. W.itemInfoCalls)

-- ---------------------------------------------------------------------------
H.section("the breakdown reads as a sentence, in quality colour")
-- ---------------------------------------------------------------------------

-- ORDER. "78% Dream Dust x1.5" answers how often, what, how many -- the order
-- the question is asked. The old form put the quantity before the name, which
-- reads as arithmetic and buries the material a player is scanning for in the
-- middle of the line.
A.db.SetSetting("tipDisenchantRows", true)
shiftHeld = false
local fmt = Capture()
A.tooltip.Extend(fmt, 900, 1)
local row = breakdownLineFor(fmt, "Dream Dust")
H.check("a material line exists", row ~= nil)
H.check("...the quantity is a SUFFIX, not a prefix",
        row and string.find(row.left, "x1.5", 1, true) ~= nil, row and row.left)
H.check("...and the name comes before it",
        row and string.find(row.left, "Dream Dust", 1, true)
             < string.find(row.left, "x1.5", 1, true))

-- COLOUR. A breakdown is a list of items, and a list of items in flat grey is
-- the only place in this UI that does not say at a glance which of them is the
-- valuable one. Large Radiant Shard is rare; Dream Dust is not.
H.check("names carry a quality colour escape",
        row and string.find(row.left, "|c", 1, true) ~= nil, row and row.left)
local shard = breakdownLineFor(fmt, "Large Radiant Shard")
H.check("the shard line exists", shard ~= nil)
-- A rare shard and a common dust must not read the same. Comparing the escape
-- itself, because that IS the difference a player sees.
local function colourOf(line)
    local a = string.find(line, "|c", 1, true)
    return a and string.sub(line, a, a + 9) or nil
end
H.neq("...and a rare shard does not share the common dust's colour",
      shard and colourOf(shard.left), row and colourOf(row.left))

-- ---------------------------------------------------------------------------
H.section("crafting cost, when a captured recipe makes the item")
-- ---------------------------------------------------------------------------

-- PER UNIT, not per craft. A recipe that makes four costs a quarter as much
-- per item, and this line sits beside per-unit auction prices -- comparing a
-- four-stack craft cost against one item's buyout is the mistake the divide
-- exists to prevent.
W.AddItem(910, { name = "Craftable Thing", quality = GREEN,
                 equipLoc = "", type = "Trade Goods", subType = "Cloth" })
A.db.RecordAuction(910, 5000, "Craftable Thing")
-- An earlier section clears every market price to test the unpriced path, so
-- the reagent has to be priced again here rather than relying on the top of
-- the file. Shared fixtures have already changed what two tests measured.
A.db.RecordAuction(11176, 5000, "Dream Dust")

local before = Capture()
A.tooltip.Extend(before, 910, 1)
H.isNil("nothing captured, no line", lineFor(before, "Crafting Cost:"))

-- Dream Dust is priced at 5000 above; four of them, and the recipe makes two.
A.craft.AddProject({ name = "Craftable Thing", itemId = 910, made = 2,
    reagents = { { name = "Dream Dust", itemId = 11176, count = 4 } } })
local after = Capture()
A.tooltip.Extend(after, 910, 1)
local cc = lineFor(after, "Crafting Cost:")
H.check("a captured recipe adds the line", cc ~= nil)

-- 4 x 5000 = 20000 for a craft that makes 2, so 10000 each. If the divide is
-- missing this reads 20000 and the item looks twice as expensive to make.
H.check("...divided by how many the craft makes",
        cc and string.find(cc.right, "1g", 1, true) ~= nil, cc and cc.right)

-- An unpriced reagent means no answer at all: a partial total is SMALLER than
-- the real one, and a crafting cost that reads low is the direction that loses
-- money.
-- ONE priced reagent and one not, deliberately. A recipe where nothing is
-- priced totals zero and is rejected by the zero check alone -- so it cannot
-- tell a completeness rule from its absence, and a version that answers with
-- partial totals passes.
A.craft.AddProject({ name = "Half Known", itemId = 911, made = 1,
    reagents = {
        { name = "Dream Dust", itemId = 11176, count = 1 },
        { name = "Nobody Prices This", itemId = 999123, count = 1 },
    } })
W.AddItem(911, { name = "Half Known", quality = GREEN, equipLoc = "",
                 type = "Trade Goods", subType = "Cloth" })
A.db.RecordAuction(911, 5000, "Half Known")
local partial = Capture()
A.tooltip.Extend(partial, 911, 1)
H.isNil("an unpriced reagent gives no cost rather than a low one",
        lineFor(partial, "Crafting Cost:"))

os.exit(H.report("tooltip"))
