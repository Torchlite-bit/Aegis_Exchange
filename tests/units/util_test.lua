-- Aegis: Exchange -- tests/units/util_test.lua
--
-- core/util.lua under a simulated 1.12 client. This is the layer with no
-- client dependencies at all, so everything here is exact.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore("util")
local util = A.util

-- ---------------------------------------------------------------------------
H.section("MoneyParts / FormatMoney")
-- ---------------------------------------------------------------------------

local g, s, c = util.MoneyParts(123456)
H.eq("12g of 123456 copper", g, 12)
H.eq("34s of 123456 copper", s, 34)
H.eq("56c of 123456 copper", c, 56)

-- math.mod and math.floor, not "%" and integer division -- the arithmetic the
-- Lua 5.0 rules force. A wrong split here is silent: the number still prints.
local g2, s2, c2 = util.MoneyParts(10000)
H.eq("exactly one gold -> 1g", g2, 1)
H.eq("exactly one gold -> 0s", s2, 0)
H.eq("exactly one gold -> 0c", c2, 0)

local g3, s3, c3 = util.MoneyParts(99)
H.eq("under a silver -> 0g", g3, 0)
H.eq("under a silver -> 0s", s3, 0)
H.eq("under a silver -> 99c", c3, 99)

H.eq("nil is treated as zero", util.FormatMoney(nil), "0c")
H.eq("zero shows copper, not empty", util.FormatMoney(0), "0c")
H.eq("leading zero denominations dropped", util.FormatMoney(10000), "1g")
H.eq("interior zero denomination dropped too",
     util.FormatMoney(10000 + 5), "1g 5c")
H.eq("all three", util.FormatMoney(123456), "12g 34s 56c")

-- Negative input is normalised rather than printing a "-" mid-string. Deposit
-- and profit maths can go negative and this is the display path for both.
H.eq("negative is absolute", util.FormatMoney(-123456), "12g 34s 56c")

-- ---------------------------------------------------------------------------
H.section("FormatMoneyGold")
-- ---------------------------------------------------------------------------

-- The Buy table's format: value bright, unit letter dim. Colour codes are part
-- of the contract -- a FontString has one font on 1.12, so the |c escapes are
-- the ONLY way this reads as "number then unit".
local fm = util.FormatMoneyGold(123456)
H.check("gold digits carry the bright code",
        string.find(fm, "|cffffd70012|r", 1, true) ~= nil, fm)
H.check("unit letter carries the dim code",
        string.find(fm, "|cff9d8b5ag|r", 1, true) ~= nil, fm)
H.check("zero still prints a copper figure",
        string.find(util.FormatMoneyGold(0), "0", 1, true) ~= nil,
        util.FormatMoneyGold(0))

-- ---------------------------------------------------------------------------
H.section("ParseMoney")
-- ---------------------------------------------------------------------------

H.eq("round trip 12g 34s 56c", util.ParseMoney("12g 34s 56c"), 123456)
H.eq("spaces optional", util.ParseMoney("12g34s56c"), 123456)
H.eq("case insensitive", util.ParseMoney("12G 34S 56C"), 123456)
H.eq("partial denominations", util.ParseMoney("5g"), 50000)
H.eq("silver only", util.ParseMoney("7s"), 700)
H.eq("copper only", util.ParseMoney("9c"), 9)
H.isNil("nothing parseable returns nil", util.ParseMoney("hello"))
H.isNil("empty string returns nil", util.ParseMoney(""))
H.isNil("a non-string returns nil", util.ParseMoney(42))
H.isNil("nil returns nil", util.ParseMoney(nil))

-- nil and 0 must stay distinguishable: "could not read this" and "free" are
-- different answers, and a price field that confuses them posts an auction at
-- the wrong number.
H.neq("unparseable is nil, NOT zero", util.ParseMoney("abc"), 0)

-- ---------------------------------------------------------------------------
H.section("Split / Trim / ItemIdFromLink")
-- ---------------------------------------------------------------------------

local parts, n = util.Split("a b  c")
H.eq("split drops empty tokens", n, 3)
H.listEq("split on whitespace", parts, { "a", "b", "c" })

local csv, cn = util.Split("x,y,z", ",")
H.eq("split on a given separator", cn, 3)
H.listEq("split on comma", csv, { "x", "y", "z" })

local none, nn = util.Split(nil)
H.eq("split of nil is empty", nn, 0)

H.eq("trim both ends", util.Trim("  padded  "), "padded")
H.eq("trim leaves interior spaces", util.Trim("  a b  "), "a b")
H.eq("trim of an untouched string", util.Trim("clean"), "clean")

-- Trim returns ONE value. It uses gsub, which returns two, and a bare
-- `return string.gsub(...)` would leak the substitution count into any caller
-- doing f(util.Trim(x), y) -- shifting every later argument along.
local function countReturns(...) return select("#", ...) end
H.eq("Trim returns exactly one value", countReturns(util.Trim(" x ")), 1)

H.eq("id from a full link",
     util.ItemIdFromLink("|cffffffff|Hitem:2589:0:0:0|h[Linen Cloth]|h|r"), 2589)
H.eq("id from a bare item string", util.ItemIdFromLink("item:2589:0:0:0"), 2589)
H.isNil("no id in plain text", util.ItemIdFromLink("Linen Cloth"))
H.isNil("no id in nil", util.ItemIdFromLink(nil))

-- ---------------------------------------------------------------------------
H.section("FormatDuration / FormatAgo")
-- ---------------------------------------------------------------------------

H.eq("seconds", util.FormatDuration(42), "42s")
H.eq("minutes round up", util.FormatDuration(90), "2m")
H.eq("hours and minutes", util.FormatDuration(8040), "2h 14m")
H.eq("negative clamps to zero", util.FormatDuration(-5), "0s")
H.eq("nil is zero", util.FormatDuration(nil), "0s")

H.eq("under a minute", util.FormatAgo(30), "just now")
H.eq("minutes ago", util.FormatAgo(300), "5m ago")
H.eq("hours ago", util.FormatAgo(8040), "2h 14m ago")
H.eq("days ago", util.FormatAgo(3 * 86400), "3d ago")

-- ---------------------------------------------------------------------------
H.section("Table helpers")
-- ---------------------------------------------------------------------------

local src = { a = 1, b = 2 }
local cp = util.CopyTable(src)
cp.a = 99
H.eq("CopyTable does not write through", src.a, 1)

-- CopyList is one level deeper, and the reason is concrete: post-filter clause
-- lists are handed between the builder's live state and parsed terms, and a
-- shallow copy let an edit in one show up in the other.
local list = { { op = "eq", v = 1 }, { op = "gt", v = 2 } }
local lc = util.CopyList(list)
lc[1].v = 99
H.eq("CopyList copies the RECORDS, not just the array", list[1].v, 1)
H.eq("CopyList keeps the length", table.getn(lc), 2)
H.eq("CopyList of nil is empty", table.getn(util.CopyList(nil)), 0)

local found, idx = util.ArrayContains({ "x", "y", "z" }, "y")
H.check("ArrayContains finds", found, tostring(found))
H.eq("ArrayContains returns the index", idx, 2)
local missing = util.ArrayContains({ "x" }, "q")
H.eq("ArrayContains reports absence as false", missing, false)

H.eq("CountKeys counts hash entries", util.CountKeys({ a = 1, b = 2, c = 3 }), 3)
H.eq("CountKeys of empty", util.CountKeys({}), 0)

-- ---------------------------------------------------------------------------
H.section("ItemInfo -- the vanilla 9-value shape")
-- ---------------------------------------------------------------------------

W.AddItem(2589, {
    name = "Linen Cloth", quality = 1, minLevel = 0,
    type = "Trade Goods", subType = "Cloth", stackCount = 20,
    equipLoc = "", texture = "linen",
})

local info = util.ItemInfo(2589)
H.check("ItemInfo answers for a cached item", info ~= nil, tostring(info))
H.eq("name", info.name, "Linen Cloth")
H.eq("quality", info.quality, 1)

-- The whole point of ItemInfo: stackCount is found by anchoring on the LAST
-- NUMBER, not by a fixed index, because later clients insert itemLevel at slot
-- 4 and shift everything after it. Reading a fixed position is wrong on one
-- client or the other, silently -- and /stack shipped broken for four rounds
-- because of exactly that.
H.eq("stackCount found by anchoring, not by index", info.stackCount, 20)
H.eq("type is one slot back from stackCount", info.type, "Trade Goods")
H.eq("subType is the slot before stackCount", info.subType, "Cloth")
H.eq("minLevel is three slots back", info.minLevel, 0)

H.isNil("uncached item returns nil", util.ItemInfo(999999))
H.isNil("nil link returns nil", util.ItemInfo(nil))

-- A stack size of 1 is a real answer and must not read as "unknown". The
-- unknown-stack path is what suppresses rows in /stack searches.
W.AddItem(12345, {
    name = "Bind on Pickup Thing", quality = 3, stackCount = 1,
    type = "Armor", subType = "Cloth", equipLoc = "INVTYPE_CHEST",
})
local one = util.ItemInfo(12345)
H.eq("stackCount of 1 is reported as 1", one.stackCount, 1)
H.eq("equipLoc is one slot FORWARD of stackCount",
     one.equipLoc, "INVTYPE_CHEST")

-- ---------------------------------------------------------------------------
H.section("ItemInfo -- the SAME code against the 10-value later shape")
-- ---------------------------------------------------------------------------

-- Reading a fixed index is right on exactly ONE client and silently wrong on
-- the other: with itemLevel inserted at slot 4, index 7 stops being stackCount
-- and becomes subType. Running the same assertions against both shapes is the
-- only thing that can tell the anchor apart from a lucky constant -- with just
-- the vanilla shape below, `stackCount = r[7]` passes every check above.
W.itemInfoShape = "later"

local later = util.ItemInfo(2589)
H.eq("name still reads absolutely", later.name, "Linen Cloth")
H.eq("quality still reads absolutely", later.quality, 1)
H.eq("stackCount is STILL found on the shifted shape", later.stackCount, 20)
H.eq("type is still resolved correctly", later.type, "Trade Goods")
H.eq("subType is still resolved correctly", later.subType, "Cloth")

local laterOne = util.ItemInfo(12345)
H.eq("a stack of 1 survives the shift too", laterOne.stackCount, 1)
H.eq("equipLoc survives the shift", laterOne.equipLoc, "INVTYPE_CHEST")

W.itemInfoShape = "vanilla"          -- leave the client as we found it

-- ---------------------------------------------------------------------------
H.section("ItemInfo -- a MISS is a server query, so misses are paced")
-- ---------------------------------------------------------------------------

-- WHY THIS EXISTS. On 1.12 GetItemInfo answers from the client's item cache,
-- and for an item that is NOT in it the client asks the SERVER and returns nil
-- meanwhile. Nothing remembers the nil, so a caller that asks on every tooltip
-- sends one query per hover for ever.
--
-- Measured against the real ui/frame.lua before this gate existed: re-hovering
-- ONE auction row twenty times cost twenty GetItemInfo calls, and sweeping
-- forty rows cost thirty-two. The tabs whose items are least likely to be
-- cached -- Auctions, History, Crafting, drawing from mail, the ledger and
-- recipe reagents -- are exactly the lists a player sweeps, and that is the
-- freeze-then-crash to desktop.
--
-- The numbers below are the whole point of the section. An assertion that the
-- gate merely "returns nil sometimes" would pass with the storm intact.

util.ForgetMisses()
W.items = {}                          -- nothing cached: every lookup misses

W.itemInfoCalls = 0
H.isNil("an uncached item still answers nil", util.ItemInfo(90001))
H.eq("...and that first ask DID reach the client", W.itemInfoCalls, 1)

W.itemInfoCalls = 0
local i = 1
while i <= 20 do util.ItemInfo(90001); i = i + 1 end
H.eq("re-asking the SAME item 20x costs nothing", W.itemInfoCalls, 0)

-- A sweep down a list of DIFFERENT uncached items is the other half: a
-- per-item cooldown alone would not stop it, because every row is a new id.
util.ForgetMisses()
W.itemInfoCalls = 0
i = 1
while i <= 40 do util.ItemInfo(91000 + i); i = i + 1 end
H.check("40 DIFFERENT uncached items cost a bounded few, not 40",
    W.itemInfoCalls <= 5, "got " .. W.itemInfoCalls)

-- Paced, NOT blocked for ever: the query that did go out warms the cache, and
-- the next lookup past the cooldown has to be able to pick the answer up.
util.ForgetMisses()
util.ItemInfo(90002)
W.AddItem(90002, { name = "Now Cached", quality = 2, minLevel = 1,
    type = "Armor", subType = "Cloth", stackCount = 1,
    equipLoc = "INVTYPE_CHEST", texture = "t" })
H.isNil("still silent inside the cooldown", util.ItemInfo(90002))
W.Advance(60)
local warmed = util.ItemInfo(90002)
H.eq("and answers once the cooldown has passed", warmed and warmed.name,
    "Now Cached")

-- THE REGRESSION THAT WOULD HURT MOST. Only MISSES pay: a list whose items are
-- all cached is the Buy tab and the bag browser, and pacing those would break
-- the addon far more visibly than the crash did.
util.ForgetMisses()
i = 1
while i <= 61 do
    W.AddItem(92000 + i, { name = "Cached " .. i, quality = 2, minLevel = 1,
        type = "Armor", subType = "Cloth", stackCount = 1,
        equipLoc = "INVTYPE_CHEST", texture = "t" })
    i = i + 1
end
W.itemInfoCalls = 0
local resolved = 0
i = 1
while i <= 61 do
    if util.ItemInfo(92000 + i) then resolved = resolved + 1 end
    i = i + 1
end
H.eq("61 cached items all resolve", resolved, 61)
H.eq("...and none of them was paced", W.itemInfoCalls, 61)

util.ForgetMisses()

os.exit(H.report("util"))
