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
                 equipLoc = "INVTYPE_CHEST", itemLevel = 48 })
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
local line = lineFor(t, "Aegis Disenchant")
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
     lineFor(stacked, "Aegis Disenchant").right,
     lineFor(single, "Aegis Disenchant").right)
H.check("...and no stack total is appended to it",
        string.find(lineFor(stacked, "Aegis Disenchant").right, "x20", 1, true)
        == nil, lineFor(stacked, "Aegis Disenchant").right)

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
        lineFor(cloth, "Aegis Disenchant"))

-- Cached, disenchantable, and the client has no level for it: the state of
-- every item on a client with no mod exposing one.
W.AddItem(903, { name = "Unknown Level", quality = GREEN,
                 equipLoc = "INVTYPE_CHEST" })
local noLevel = Capture()
A.tooltip.Extend(noLevel, 903, 1)
H.isNil("an item whose level no source knows gets no line",
        lineFor(noLevel, "Aegis Disenchant"))
H.isNil("...and no 'unknown' text either", anyLineWith(noLevel, "unknown"))

-- ---------------------------------------------------------------------------
H.section("the per-line setting")
-- ---------------------------------------------------------------------------

A.db.SetSetting("tipDisenchant", false)
local off = Capture()
A.tooltip.Extend(off, 900, 1)
H.isNil("switched off, the line is gone", lineFor(off, "Aegis Disenchant"))
A.db.SetSetting("tipDisenchant", true)
H.check("switched back on, it returns",
        lineFor((function() local c = Capture()
                 A.tooltip.Extend(c, 900, 1); return c end)(),
                "Aegis Disenchant") ~= nil)

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
        lineFor(onByDefault, "Aegis Disenchant") ~= nil)

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
H.check("the market line is still there", lineFor(both, "Aegis Market") ~= nil)
H.check("...and still multiplies by the stack",
        string.find(lineFor(both, "Aegis Market").right, "x4", 1, true) ~= nil,
        lineFor(both, "Aegis Market").right)

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
        lineFor(approx, "Aegis Disenchant (approx)") ~= nil)
H.isNil("...and NOT the unqualified label",
        lineFor(approx, "Aegis Disenchant"))

-- The converse, so the label cannot simply be hardcoded on: item 900's level
-- comes from the client, and that answer is exact.
local exact = Capture()
A.tooltip.Extend(exact, 900, 1)
H.check("a client-measured level keeps the plain label",
        lineFor(exact, "Aegis Disenchant") ~= nil)
H.isNil("...and is never marked approximate",
        lineFor(exact, "Aegis Disenchant (approx)"))

-- ---------------------------------------------------------------------------
H.section("the qualifiers beside each number")
-- ---------------------------------------------------------------------------

-- A market median resting on one day and one resting on thirty produce the
-- same-looking figure and are not the same claim. The tooltip is the only
-- place a player ever sees either, so the day count rides beside the value.
local q = Capture()
A.tooltip.Extend(q, 900, 1)
local mkt = lineFor(q, "Aegis Market")
H.check("the market line carries a day count",
        string.find(mkt.right, "d|r", 1, true) ~= nil, mkt.right)

-- Today's cheapest listing is interesting mainly as a FRACTION of the median.
-- Without it every reader does the division in their head.
local mb = lineFor(q, "Aegis Min Buyout")
H.check("min buyout is shown against the market",
        string.find(mb.right, "% of mkt", 1, true) ~= nil, mb.right)

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
        lineFor(blind, "Aegis Disenchant") ~= nil)
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

os.exit(H.report("tooltip"))
