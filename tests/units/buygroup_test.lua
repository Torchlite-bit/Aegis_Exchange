-- Aegis: Exchange -- tests/units/buygroup_test.lua
--
-- Grouped Buy results: one row per ITEM, expandable to the individual
-- auctions underneath it, and a right-click that searches for that item and
-- nothing else.
--
-- WHAT IS ACTUALLY ARITHMETIC HERE, and every one of these has a way to be
-- wrong that reads as working:
--
--   * the GROUP KEY. Two different items can share a name on this client, and
--     merging them totals two markets into one price;
--   * the LOWEST price. A bid-only auction is a listing you can see and not a
--     price you can pay, so counting it quotes a number nobody can buy at;
--   * `open` keyed by KEY and not by index, because a re-sort renumbers every
--     row and an index-keyed set then expands whichever item slid into the
--     slot;
--   * and the bracket term, which has to mean the same thing to the parser
--     that `/exact` already means.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)
local buy = A.buy

-- The UI half lives in ui/frame.lua, which no suite loads. Extracted at run
-- time rather than copied -- a duplicate would drift, and this is the drift
-- that shows as a row expanding the wrong item.
local function Source(path)
    local f = assert(io.open(path, "r"), "run this from the repo root")
    local src = f:read("*a")
    f:close()
    return src
end

local function extract(path, signature)
    local body, grabbing = {}, false
    for line in string.gfind(Source(path), "([^\n]*)\n") do
        if not grabbing then
            if string.find(line, signature, 1, true) == 1 then
                grabbing = true
                table.insert(body, line)
            end
        else
            table.insert(body, line)
            if line == "end" then break end
        end
    end
    if not grabbing then error("did not find: " .. signature) end
    return table.concat(body, "\n")
end

ui = {}
for _, sig in ipairs({
    "function ui.BuyTreeRows(",
    "function ui.ToggleBuyGroup(",
}) do
    local fn, err = loadstring(extract("ui/frame.lua", sig), sig)
    if not fn then error(sig .. " will not compile: " .. tostring(err)) end
    fn()
end

-- ---------------------------------------------------------------------------
H.section("one row per item")
-- ---------------------------------------------------------------------------

-- A page of "mana": three Greater Mana Potions from three sellers, one Minor,
-- and one bid-only Greater that nobody can buy outright.
local PAGE = {
    { name = "Greater Mana Potion", itemId = 3827, count = 1, unit = 569,
      buyout = 569, owner = "Valarich", quality = 1 },
    { name = "Minor Mana Potion",   itemId = 2455, count = 2, unit = 37,
      buyout = 74, owner = "Thesheep", quality = 1 },
    { name = "Greater Mana Potion", itemId = 3827, count = 5, unit = 562,
      buyout = 2810, owner = "Tekbank", quality = 1 },
    { name = "Greater Mana Potion", itemId = 3827, count = 2, unit = nil,
      buyout = 0, owner = "Luckym", quality = 1 },
}

local g = buy.GroupListings(PAGE)
H.eq("four listings become two items", table.getn(g), 2)

-- FIRST SEEN ORDER, not sorted. The caller sorts for display; ui.SortResults
-- already owns that job and two functions sorting is two answers.
H.eq("the first group is the first item seen", g[1].name, "Greater Mana Potion")
H.eq("...and the second is the second", g[2].name, "Minor Mana Potion")

H.eq("a group counts its listings", g[1].listings, 3)
H.eq("...and the units across them", g[1].units, 8)
H.eq("a lone listing is a group of one", g[2].listings, 1)
H.eq("...with its own units", g[2].units, 2)

-- THE LOWEST PRICE YOU CAN ACTUALLY PAY. Tekbank's 562 beats Valarich's 569,
-- and Luckym's bid-only auction sets nothing -- there is no price at which you
-- can take it home.
H.eq("the lowest unit buyout wins", g[1].low, 562)
H.check("...and a bid-only listing does not set it", g[1].low ~= nil,
        "a bid-only auction quoted a price nobody can buy at")

-- ...but it is still a LISTING. It is on the auction house and the parent row
-- says how many are.
H.eq("a bid-only auction still counts as a listing", g[1].listings, 3)

-- An item nobody is selling outright has NO lowest price, and must say so
-- rather than reporting zero -- a zero here reads as free.
local bidOnly = buy.GroupListings({
    { name = "Arcanite Bar", itemId = 12360, count = 1, unit = nil, buyout = 0 },
})
H.eq("an all-bid group has no lowest price", bidOnly[1].low, nil)

H.eq("an empty page is no groups", table.getn(buy.GroupListings({})), 0)
H.eq("...and a nil one too", table.getn(buy.GroupListings(nil)), 0)

-- ---- the key ------------------------------------------------------------

-- TWO ITEMS CAN SHARE A NAME. A recipe and the thing it teaches is the usual
-- pair. Grouping by name totals two separate markets into one price -- and the
-- price it reports is the lower of the two, which is the direction that reads
-- as a bargain.
local SAMENAME = {
    { name = "Gloves of Manathirst", itemId = 7048, count = 1, unit = 2000,
      buyout = 2000 },
    { name = "Gloves of Manathirst", itemId = 9999, count = 1, unit = 11,
      buyout = 11 },
}
local sn = buy.GroupListings(SAMENAME)
H.eq("two ids with one name stay two groups", table.getn(sn), 2)
H.eq("...each with its own price", sn[1].low, 2000)
H.eq("...and its own", sn[2].low, 11)

-- ...and a row whose link has not resolved yet has no id. That is a real state
-- on 1.12, not an error: it falls back to the name so the row still groups.
local NOID = {
    { name = "Dreamfoil", count = 1, unit = 100, buyout = 100 },
    { name = "Dreamfoil", count = 1, unit = 90,  buyout = 90 },
}
H.eq("rows with no id group by name", table.getn(buy.GroupListings(NOID)), 1)
H.eq("...and still find the lowest", buy.GroupListings(NOID)[1].low, 90)

-- An id and a name are never the same key, so an unresolved row does not merge
-- into the resolved group and halve its own count.
local MIXED = {
    { name = "Dreamfoil", itemId = 13463, count = 1, unit = 100 },
    { name = "Dreamfoil", count = 1, unit = 90 },
}
H.eq("a resolved and an unresolved row are separate groups",
     table.getn(buy.GroupListings(MIXED)), 2)

-- ---------------------------------------------------------------------------
H.section("expanding a group")
-- ---------------------------------------------------------------------------

local function kinds(rows)
    local out = {}
    for i = 1, table.getn(rows) do table.insert(out, rows[i].kind) end
    return table.concat(out, ",")
end

local closed = ui.BuyTreeRows(g, {})
H.eq("closed, it is one row per item", kinds(closed), "group,group")
H.eq("a group carries its count", closed[1].listings, 3)
H.eq("...and its lowest price", closed[1].low, 562)

local open = ui.BuyTreeRows(g, { [g[1].key] = true })
H.eq("expanding adds its listings underneath it", kinds(open),
     "group,listing,listing,listing,group")
H.check("...and the group says it is open", open[1].expanded,
        "the flag did not follow")
H.eq("the children are that item's listings", open[2].owner, "Valarich")
H.eq("...in the order the page gave them", open[3].owner, "Tekbank")

-- NOT A COPY. The paint reads price, seller, stack and time left straight off
-- the engine's row, and a copy is a second table to keep in step.
H.check("a child row IS the engine's row", open[2] == PAGE[1],
        "the tree copied the listings instead of listing them")

-- A GROUP OF ONE NEVER EXPANDS. There is nothing under it but the row you are
-- already looking at, and a triangle that reveals a copy of its own parent
-- reads as a bug.
H.eq("a lone listing is not expandable", closed[2].expandable, nil)
local lone = ui.BuyTreeRows(g, { [g[2].key] = true })
H.eq("...and does not expand even when asked", kinds(lone), "group,group")
H.check("a group of several IS expandable", closed[1].expandable,
        "three listings should offer a triangle")

-- ---- open is keyed by KEY, not by index ---------------------------------

-- THE REINDEXING TRAP. Sort by price and every row moves. A set keyed by index
-- would leave whichever item slid into that slot expanded -- silently, and
-- looking entirely reasonable.
local REORDERED = { g[2], g[1] }
local moved = ui.BuyTreeRows(REORDERED, { [g[1].key] = true })
H.eq("a re-sort keeps the shape", kinds(moved),
     "group,group,listing,listing,listing")
-- Greater Mana Potion was at index 1 and is now at index 2. It is still the
-- one that is open; an index-keyed set would have expanded whatever took
-- slot 1, which is the Minor.
H.eq("the SAME item is open after a re-sort", moved[2].name,
     "Greater Mana Potion")
H.check("...and it is the expanded one", moved[2].expanded,
        "the flag did not travel with the item")
H.eq("the item that took its index is not open", moved[1].name,
     "Minor Mana Potion")
H.check("...and says so", not moved[1].expanded,
        "the row that slid into slot 1 was expanded instead")

H.eq("nothing open is one row per item",
     kinds(ui.BuyTreeRows(g, nil)), "group,group")
H.eq("no groups is no rows", table.getn(ui.BuyTreeRows(nil, {})), 0)

-- ---- toggling ------------------------------------------------------------

local state = {}
ui.ToggleBuyGroup(state, "i3827")
H.eq("toggling opens it", state["i3827"], true)
ui.ToggleBuyGroup(state, "i3827")
-- NIL, NOT FALSE. Closed is nearly every group, and a key per closed group is
-- a set that grows with every page you ever scan.
H.eq("...and toggling again clears it to nil", state["i3827"], nil)
ui.ToggleBuyGroup(state, "i2455")
H.eq("a second group opens on its own", state["i2455"], true)
H.eq("...without touching the first", state["i3827"], nil)

H.survives("a nil key is not a crash", function()
    ui.ToggleBuyGroup(state, nil)
end)
H.survives("a nil set is not a crash", function()
    ui.ToggleBuyGroup(nil, "i3827")
end)

-- ---------------------------------------------------------------------------
H.section("right-click: this item and nothing else")
-- ---------------------------------------------------------------------------

H.eq("an exact term is the name in brackets",
     buy.ExactTerm("Greater Mana Potion"), "[Greater Mana Potion]")
H.eq("...trimmed", buy.ExactTerm("  Dreamfoil  "), "[Dreamfoil]")

-- "[]" would parse as a name search for a literal pair of brackets and match
-- nothing at all -- the same silent-empty failure the exact filter already
-- guards against at buy.CompileTerm.
H.eq("an empty name is an empty term, not []", buy.ExactTerm(""), "")
H.eq("...and a nil one too", buy.ExactTerm(nil), "")

-- ---- and the parser agrees with it --------------------------------------

local t = buy.ParseTerm("[Greater Mana Potion]")
H.check("brackets mean exact", t.exact, "the bracket form was read as a name")
H.eq("...on the name inside them", t.name, "Greater Mana Potion")

-- THE SAME THING /exact ALREADY MEANT. Two spellings, one meaning -- if these
-- ever diverge, a right-click and a typed query stop agreeing.
local slash = buy.ParseTerm("exact/Greater Mana Potion")
H.eq("the bracket form matches the slash form", t.exact, slash.exact)
H.eq("...including the name", t.name, slash.name)

-- A bare name is NOT exact. This is the default search and it has to stay a
-- substring match, or "mana" stops finding Mana Potion.
local plain = buy.ParseTerm("Greater Mana Potion")
H.check("a bare name is not exact", not plain.exact,
        "every search just became an exact match")

-- An unclosed bracket is a name, not a broken query. People mistype.
local half = buy.ParseTerm("[Greater Mana")
H.check("an unclosed bracket is just a name", not half.exact,
        "a typo turned into an exact search")
H.eq("...kept as typed", half.name, "[Greater Mana")

-- Brackets round-trip: what ExactTerm writes is what ParseTerm reads.
local round = buy.ParseTerm(buy.ExactTerm("Black Lotus"))
H.check("what a right-click writes, the parser reads", round.exact,
        "the two halves of exact-match disagree")
H.eq("...as the same item", round.name, "Black Lotus")

os.exit(H.report("buygroup"))
