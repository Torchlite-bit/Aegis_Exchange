-- Aegis: Exchange -- tests/units/blacklist_test.lua
--
-- The Post All blacklist (ROADMAP 5.5): items Post All never offers.
--
-- Asked for as: "a blacklist on items you don't want or never want to sell",
-- with a manager -- select items from your bags, drag and drop them in, see
-- the icon and name, remove and clear easily.
--
-- What this pins:
--   * the store is a GROUP (ROADMAP 4.1), keeping the name and icon it was
--     given, because 1.12 forgets items you no longer hold;
--   * BOTH halves of Post All leave listed items out -- the Scan, and the
--     Post / Skip walk after it -- through one shared list;
--   * a drop finds the item on the cursor without a hook;
--   * an item Post All would never offer anyway is refused, not silently kept;
--   * it is not a lock: a listed item can still be posted by hand.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)
local db, sell = A.db, A.sell
local KEY = db.GROUP_NO_POST

W.AddItem(2589, { name = "Linen Cloth", quality = 1, stackCount = 20,
                  texture = "Interface\\Icons\\linen" })
W.AddItem(4306, { name = "Silk Cloth", quality = 1, stackCount = 20,
                  texture = "Interface\\Icons\\silk" })
W.AddItem(2592, { name = "Wool Cloth", quality = 1, stackCount = 20,
                  texture = "Interface\\Icons\\wool" })
local LINEN, SILK, WOOL = W.items[2589].link, W.items[4306].link,
                          W.items[2592].link

local function ids(list)
    local out = {}
    for i = 1, table.getn(list or {}) do out[list[i].itemId] = true end
    return out
end

-- ---------------------------------------------------------------------------
H.section("The store is a group, and remembers what it was shown")
-- ---------------------------------------------------------------------------

H.check("the save has a groups table", type(db.account.groups) == "table")
H.eq("nothing listed to begin with", db.GroupCount(KEY), 0)
H.eq("adding is news", db.GroupAdd(KEY, 4306, "Silk Cloth", "silk.tga"), true)
H.eq("adding again is not", db.GroupAdd(KEY, 4306, "Silk Cloth", "silk.tga"),
     false)
H.check("it is in", db.GroupHas(KEY, 4306))
H.eq("one entry, however often it was added", db.GroupCount(KEY), 1)
H.check("other groups are separate", not db.GroupHas("other", 4306))

-- THE NAME AND ICON ARE KEPT. An item you sold your last one of drops out of
-- the client's cache, and a list of bare ids shows blank rows for exactly the
-- items you decided never to post.
local list = db.GroupList(KEY)
H.eq("the list keeps the name", list[1] and list[1].name, "Silk Cloth")
H.eq("...and the icon", list[1] and list[1].texture, "silk.tga")
-- An add with nothing to say keeps what it had.
db.GroupAdd(KEY, 4306)
H.eq("an add without a name keeps the old one",
     db.GroupList(KEY)[1].name, "Silk Cloth")

db.GroupAdd(KEY, 2589, "Linen Cloth")
db.GroupAdd(KEY, 99999)                     -- never had a name
list = db.GroupList(KEY)
H.eq("listed by name", list[1].name, "Linen Cloth")
H.eq("...then by name", list[2].name, "Silk Cloth")
H.eq("...and a nameless entry last, not first", list[3].itemId, 99999)

H.eq("removing says it was there", db.GroupRemove(KEY, 99999), true)
H.eq("...and removing again says it was not", db.GroupRemove(KEY, 99999), false)
db.GroupClear(KEY)
H.eq("clear empties it", db.GroupCount(KEY), 0)

-- A save from before groups existed gains the table at load.
db.account.groups = nil
db.Init()
H.check("an older save gets a groups table", type(db.account.groups) == "table")

-- ---------------------------------------------------------------------------
H.section("Post All leaves listed items out -- both halves of it")
-- ---------------------------------------------------------------------------

W.SetBags({ [0] = {
    { link = LINEN, count = 20, texture = "Interface\\Icons\\linen" },
    { link = SILK,  count = 20, texture = "Interface\\Icons\\silk" },
    { link = WOOL,  count = 20, texture = "Interface\\Icons\\wool" },
} })
sell.BlacklistAdd(4306, "Silk Cloth")
local items, skipped = sell.PostAllItems()
local got = ids(items)
H.check("Linen is offered", got[2589])
H.check("Wool is offered", got[2592])
H.check("Silk, which is listed, is not", not got[4306])
H.eq("...and is counted as left out", skipped, 1)

-- The Scan walks the same list -- a listed item costs no query either.
sell.ScanAllBags(nil, nil)
local scanned = ids(sell.batchQueue)
H.check("the Scan leaves the listed item out too", not scanned[4306])
H.check("...and keeps the rest", scanned[2589] and scanned[2592])
if sell.StopBatchScan then sell.StopBatchScan() end

-- ...and so does the walk after it, whatever its own switches say.
H.check("the walk's queue leaves it out",
        not ids(sell.PostAllQueue(false, false))[4306])
H.check("...gated and ordered too", not ids(sell.PostAllQueue(true, true))[4306])
local _, blq = sell.PostAllQueue(false, false)
H.eq("...and counts it", blq, 1)

sell.BlacklistRemove(4306)
H.check("taken off the list, it is offered again", ids(sell.PostAllItems())[4306])

-- ---------------------------------------------------------------------------
H.section("Adding from a bag slot")
-- ---------------------------------------------------------------------------

local ok, name = sell.BlacklistAddFromBag(0, 2)
H.eq("a bag item is added", ok, true)
H.eq("...named", name, "Silk Cloth")
H.check("...and listed", sell.IsBlacklisted(4306))
H.eq("...with its icon", sell.Blacklist()[1].texture, "Interface\\Icons\\silk")

local okE, whyE = sell.BlacklistAddFromBag(0, 9)
H.eq("an empty slot is refused", okE, false)
H.check("...with a reason", whyE ~= nil)

-- Soulbound, quest and conjured items are never in Post All. Listing one
-- would look like it did something and do nothing -- so it says so instead.
local realAuctionable = sell.IsAuctionable
sell.IsAuctionable = function() return false end
local okS, whyS = sell.BlacklistAddFromBag(0, 3)
sell.IsAuctionable = realAuctionable
H.eq("an item Post All never offers is refused", okS, false)
H.check("...saying why", whyS and string.find(whyS, "never offers", 1, true) ~= nil,
        tostring(whyS))
H.check("...and is not listed", not sell.IsBlacklisted(2592))

-- ---------------------------------------------------------------------------
H.section("A drop finds the item on the cursor, with no hook")
-- ---------------------------------------------------------------------------

-- 1.12 has no GetCursorInfo. An item picked up out of a bag leaves its slot
-- LOCKED until it is put down, so the locked slot is where it came from.
W.SetBags({ [0] = {
    { link = LINEN, count = 20 },
    { link = WOOL,  count = 20, locked = true },
} })
H.isNil("nothing on the cursor, nothing found", sell.CursorBagItem())
W.cursor = { link = WOOL, count = 20 }
local cb, cs = sell.CursorBagItem()
H.eq("the locked slot is the one in hand: bag", cb, 0)
H.eq("...slot", cs, 2)
W.bags[0][2].locked = nil
H.isNil("an item in hand from somewhere else is not guessed at",
        sell.CursorBagItem())
W.cursor = nil

-- ---------------------------------------------------------------------------
H.section("Not a lock: a listed item can still be posted by hand")
-- ---------------------------------------------------------------------------

sell.BlacklistAdd(2589, "Linen Cloth")
W.SetBags({ [0] = { { link = LINEN, count = 20 } } })
W.sellSlot = { link = LINEN, count = 20, bag = 0, slot = 1 }
W.posted = {}
sell.Post(100, 100, 480)
H.eq("posting a listed item by hand still posts it", table.getn(W.posted), 1)
sell.BlacklistClear()
H.eq("Clear all empties the list", table.getn(sell.Blacklist()), 0)

-- ---------------------------------------------------------------------------
H.section("The Sell tab: what ui/frame.lua does with it")
-- ---------------------------------------------------------------------------

-- No suite loads ui/frame.lua; these read its source.
local f = assert(io.open("ui/frame.lua", "r"))
local src = f:read("*a")
f:close()
local function bodyOf(head)
    local at = string.find(src, head, 1, true)
    if not at then return "" end
    local stop = string.find(src, "\nend\n", at, true)
    return string.sub(src, at, stop or -1)
end
local function has(body, needle) return string.find(body, needle, 1, true) ~= nil end
-- bodyOf stops short of the closing "end"; a function to RUN needs it.
local function wholeOf(head)
    local body = bodyOf(head)
    if body == "" then return "" end
    return body .. "\nend\n"
end

H.check("the Post / Skip walk is built by Post All's queue",
        has(bodyOf("function ui.StartSellQueue("), "A.sell.PostAllQueue("))
local hook = bodyOf("function ui.HookBagRightClick(")
local blAt = string.find(hook, "ui.BlacklistPickActive()", 1, true)
local sellAt = string.find(hook, "ui.SellRightClickActive()", 1, true)
H.check("with the panel open, a right-click in your bags lists the item",
        blAt ~= nil)
H.check("...and that comes before slotting it",
        blAt and sellAt and blAt < sellAt)
-- A refused right-click still counts as handled: falling through would USE
-- the item -- drink the potion, equip the gear.
local try = bodyOf("function ui.TryBlacklistFromBag(")
H.check("a refused right-click is still handled",
        has(try, "if not ok then ChatMsg")
        and has(try, "BlacklistChanged()\n    return true"))
H.check("Your Bags rows take a right-click",
        has(src, 'row:RegisterForClicks("LeftButtonUp", "RightButtonUp")\n'
            .. '            row:SetScript("OnClick", function()\n'
            .. '                local e = row.entry\n'
            .. '                if not (e and e.kind == "item") then return end'))
H.check("...which puts the item on or off the list",
        has(src, "ui.ToggleBlacklistEntry(e.item)"))
H.check("listed rows are drawn dimmed",
        has(bodyOf("function ui.UpdateBagList("), "A.sell.IsBlacklisted(it.itemId)"))
H.check("...and every row resets its icon, since rows are pooled",
        has(bodyOf("function ui.UpdateBagList("), "row.icon:SetVertexColor(1, 1, 1)"))
H.check("the drop target takes a drag",
        has(bodyOf("function ui.BuildBlacklist("),
            'drop:SetScript("OnReceiveDrag", function() ui.BlacklistDrop() end)'))
H.check("...and a drop always empties the cursor",
        has(bodyOf("function ui.BlacklistDrop("),
            "local ok, why = A.sell.BlacklistAddFromBag(bag, slot)\n    ClearCursor()"))
H.check("the panel goes when you leave the Sell tab",
        has(src, "        ui.HideVendorList()\n        ui.HideBlacklist()\n"))
-- BAG_UPDATE storms (CLAUDE.md rule 16): the handler sets a flag and the
-- panel's own OnUpdate repaints once a frame.
local bagUpd = string.find(src, "if ui.blFrame then ui.blDirty = true end", 1, true)
H.check("a bag change marks the panel dirty", bagUpd ~= nil)
H.check("...and the panel repaints from the flag, once a frame",
        has(bodyOf("function ui.BuildBlacklist("),
            "        if ui.blDirty then\n            ui.blDirty = false\n"
            .. "            ui.RefreshBlacklist()"))
local handler = bagUpd and string.sub(src, bagUpd - 200, bagUpd) or ""
H.check("...never inline in the handler",
        bagUpd ~= nil and not has(handler, "RefreshBlacklist"))
H.check("Clear all asks first",
        has(bodyOf("function ui.ConfirmBlacklistClear("),
            'StaticPopup_Show("AEGIS_EXCHANGE_BLACKLIST_CLEAR"'))

-- The walk's status line says when the blacklist shortened it.
ui = {}
assert(loadstring(wholeOf("function ui.WalkLeftOutNote(")))()
H.eq("nothing left out says nothing", ui.WalkLeftOutNote({ blacklisted = 0 }), "")
H.eq("...nor does nil", ui.WalkLeftOutNote(nil), "")
H.eq("three left out says so", ui.WalkLeftOutNote({ blacklisted = 3 }),
     " (left out: 3 blacklisted)")

os.exit(H.report("blacklist"))
