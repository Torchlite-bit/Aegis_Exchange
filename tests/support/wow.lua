-- Aegis: Exchange -- tests/support/wow.lua
--
-- A simulated WoW 1.12 client, just large enough to LOAD the core modules and
-- drive them. Desktop Lua 5.1 only; never loaded by the client.
--
-- Scope, deliberately: this stands in for the CLIENT, not for FrameXML's look.
-- Frames answer every method the core modules call and record what they were
-- told, but they have no geometry and draw nothing. Anything whose correctness
-- is "does it look right" -- layout, colour, both skins -- is NOT testable here
-- and must not be faked into looking testable. That is a real client's job.
--
-- The 1.12 API shapes are pinned here on purpose, because getting them wrong is
-- how this addon has actually broken:
--   * GetAuctionItemInfo returns EXACTLY 12 values, and `owner` may be nil.
--   * QueryAuctionItems takes 9 args and `page` is 0-indexed.
--   * CanSendAuctionQuery gates every query.
--   * GetItemInfo returns the 9-value VANILLA list (no itemLevel at slot 4).
-- If a test passes against a wrong shape here, it proves nothing, so these are
-- asserted rather than merely provided -- see W.strictArgs below.

local W = {}

-- ---------------------------------------------------------------------------
-- Globals table
-- ---------------------------------------------------------------------------

-- On 1.12 getglobal(name) IS the global environment -- not a private registry.
-- Anything the client defines as a plain global (AUCTION_TIME_LEFT1,
-- ITEM_QUALITY_COLORS, a named frame) is reachable through it, and the addon
-- relies on that for dynamic names like "AuctionFrameTab" .. n. Backing this
-- with a side table instead made named lookups of client constants come back
-- nil, which is a difference from the real client, so it reads _G.
function getglobal(name) return _G[name] end
function setglobal(name, v) _G[name] = v end

-- ---------------------------------------------------------------------------
-- Frames
-- ---------------------------------------------------------------------------

local function noop() end

-- A frame that answers everything. Unknown methods resolve to a no-op via the
-- metatable rather than erroring, because the point of this file is to let the
-- modules LOAD -- a missing setter should not look like a logic failure. The
-- methods that carry meaning (scripts, events, show/hide) are real.
local frameMT = {}
frameMT.__index = function(t, k)
    local fn = function() end
    rawset(t, k, fn)
    return fn
end

function CreateFrame(kind, name, parent, template)
    local f = {
        frameType = kind,
        frameName = name,
        parent    = parent,
        template  = template,
        scripts   = {},
        events    = {},
        shown     = true,
        children  = {},
    }
    f.GetName        = function(self) return self.frameName end
    f.GetObjectType  = function(self) return self.frameType end
    f.GetParent      = function(self) return self.parent end
    f.SetScript      = function(self, s, fn) self.scripts[s] = fn end
    f.GetScript      = function(self, s) return self.scripts[s] end
    f.HasScript      = function(self) return true end
    f.RegisterEvent  = function(self, e) self.events[e] = true end
    f.UnregisterEvent= function(self, e) self.events[e] = nil end
    f.IsEventRegistered = function(self, e) return self.events[e] end
    f.Show           = function(self) self.shown = true end
    f.Hide           = function(self) self.shown = false end
    f.IsShown        = function(self) return self.shown end
    f.IsVisible      = function(self) return self.shown end
    f.GetChildren    = function(self) return unpack(self.children) end
    f.GetRegions     = function(self) return end
    f.GetFrameLevel  = function(self) return 1 end
    f.GetWidth       = function(self) return self.width or 0 end
    f.GetHeight      = function(self) return self.height or 0 end
    f.SetWidth       = function(self, v) self.width = v end
    f.SetHeight      = function(self, v) self.height = v end
    f.Enable         = function(self) self.disabled = nil end
    f.Disable        = function(self) self.disabled = true end
    f.IsEnabled      = function(self) if self.disabled then return nil end return 1 end
    f.SetChecked     = function(self, v) self.checked = v and true or false end
    f.GetChecked     = function(self) if self.checked then return 1 end return nil end
    f.SetText        = function(self, t) self.text = t end
    f.GetText        = function(self) return self.text end

    -- Scanning tooltips. Lines are supplied per item by W.SetTooltipLines.
    f.SetOwner       = noop
    f.ClearLines     = function(self) self.lines = {} end
    f.SetHyperlink   = function(self, link)
        self.lines = W.tooltipLines[link] or {}
    end
    f.NumLines       = function(self) return table.getn(self.lines or {}) end

    setmetatable(f, frameMT)
    if name then _G[name] = f end
    if parent and parent.children then table.insert(parent.children, f) end
    return f
end

-- Fire an event the way the 1.12 client does: set the GLOBALS, then call the
-- frame's OnEvent with no arguments. Any handler written as
-- function(self, event, ...) will read nil here, which is the point.
function W.FireEvent(frame, evt, a1, a2, a3, a4)
    event, arg1, arg2, arg3, arg4 = evt, a1, a2, a3, a4
    this = frame
    local fn = frame.scripts and frame.scripts.OnEvent
    if fn then fn() end
end

-- Run a frame's OnUpdate once, the 1.12 way: `this` is the frame and the
-- elapsed seconds arrive as the GLOBAL arg1, not as a parameter.
--
-- The client runs OnUpdate every frame, and the addon leans on that -- the
-- auction query throttle, the batch pacing and the deferred repaint all live
-- in one. Nothing happens in those paths without this, which is why a test
-- that calls buy.Search and then looks for a query sees nothing: Search only
-- arms the driver.
function W.Tick(frame, elapsed)
    if not frame then return end
    local fn = frame.scripts and frame.scripts.OnUpdate
    if not fn then return end
    this, arg1 = frame, elapsed or 0.1
    fn()
end

-- Tick until `pred` is true or `limit` ticks pass. Returns whether it settled,
-- so a test can assert on that rather than hanging.
function W.TickUntil(frame, pred, limit, elapsed)
    limit = limit or 100
    for i = 1, limit do
        if pred() then return true, i end
        W.Tick(frame, elapsed)
    end
    return pred(), limit
end

-- ---------------------------------------------------------------------------
-- Chat / misc client globals
-- ---------------------------------------------------------------------------

W.messages = {}
DEFAULT_CHAT_FRAME = {
    AddMessage = function(self, msg) table.insert(W.messages, msg) end,
}
UIParent = CreateFrame("Frame", "UIParent")

W.now = 1700000000
function time() return W.now end

W.realm   = "TestRealm"
W.player  = "Tester"
function GetRealmName() return W.realm end
function UnitName(unit) if unit == "player" then return W.player end return nil end
function UnitFactionGroup() return "Alliance" end

W.money = 500000                      -- 50g
function GetMoney() return W.money end

ITEM_QUALITY_COLORS = {
    [0] = { r = 0.62, g = 0.62, b = 0.62 },
    [1] = { r = 1.00, g = 1.00, b = 1.00 },
    [2] = { r = 0.12, g = 1.00, b = 0.00 },
    [3] = { r = 0.00, g = 0.44, b = 0.87 },
    [4] = { r = 0.64, g = 0.21, b = 0.93 },
    [5] = { r = 1.00, g = 0.50, b = 0.00 },
}

AUCTION_TIME_LEFT1 = "Short"
AUCTION_TIME_LEFT2 = "Medium"
AUCTION_TIME_LEFT3 = "Long"
AUCTION_TIME_LEFT4 = "Very Long"

-- ---------------------------------------------------------------------------
-- Items
-- ---------------------------------------------------------------------------

-- itemId -> record. GetItemInfo answers only for items placed here, which is
-- the behaviour that matters: on 1.12 it returns nil for anything not in the
-- client's cache, and code that assumes otherwise breaks on a fresh login.
W.items = {}
W.tooltipLines = {}

function W.AddItem(id, rec)
    rec.id = id
    rec.link = rec.link
        or ("|cffffffff|Hitem:" .. id .. ":0:0:0|h[" .. rec.name .. "]|h|r")
    W.items[id] = rec
    W.items[rec.name] = rec
    W.items[rec.link] = rec
    -- The client answers GetItemInfo for the bare item STRING too, and code
    -- that builds one by hand would otherwise look broken only here.
    W.items["item:" .. id .. ":0:0:0"] = rec
    return rec
end

-- GetItemInfo's return LIST is not the same on every client:
--
--   vanilla 1.12   name link quality minLevel type subType
--                  stackCount equipLoc texture                    (9 values)
--   later clients  name link quality iLevel minLevel type subType
--                  stackCount equipLoc texture                   (10 values)
--
-- itemLevel is inserted at position 4, so EVERY field after position 3 sits one
-- slot further along on a later client. util.ItemInfo therefore anchors on
-- "stackCount is the LAST NUMBER" instead of indexing a fixed position.
--
-- BOTH shapes are offered here, because a test that only ever sees one cannot
-- tell the anchor apart from a hardcoded index -- and a hardcoded index is
-- exactly the bug that shipped and cost four rounds of "why does /stack do
-- nothing". Flip with W.itemInfoShape.
-- "vanilla" (9) | "later" (10) | "wide" (18, what a client mod may install
-- in place of the global). All three are offered because util.ItemInfo's
-- anchor-on-the-last-number trick is RIGHT for the first two and exactly
-- wrong for the third -- the wide tuple has six numbers after stackCount --
-- and a test that only ever sees one shape cannot tell the anchor apart from
-- a hardcoded index.
W.itemInfoShape = "vanilla"          -- or "later" / "wide"

-- The client resolves an item from an id, a name, or ANY well-formed link --
-- the colour code in front of a link is decoration, not identity. Keying only
-- on the exact string a test happened to build made a hand-written link miss
-- while the generated one hit, which looks exactly like a bug in the addon.
local function ItemRec(key)
    local r = W.items[key]
    if r then return r end
    if type(key) == "string" then
        local _, _, id = string.find(key, "Hitem:(%d+)")
        if not id then _, _, id = string.find(key, "^item:(%d+)") end
        if id then return W.items[tonumber(id)] end
    end
    return nil
end

function GetItemInfo(key)
    local r = ItemRec(key)
    if not r then return nil end
    if W.itemInfoShape == "wide" then
        return r.name, r.link, r.quality or 1, r.itemLevel or 0,
               r.minLevel or 0, r.type or "Trade Goods",
               r.subType or "Cloth", r.stackCount or 20,
               r.equipLoc or "", r.texture or "icon",
               r.sellPrice or 0, 0, 0, 0, 0, nil, false, ""
    end
    if W.itemInfoShape == "later" then
        return r.name, r.link, r.quality or 1, r.itemLevel or 55,
               r.minLevel or 0, r.type or "Trade Goods",
               r.subType or "Cloth", r.stackCount or 20,
               r.equipLoc or "", r.texture or "icon"
    end
    return r.name, r.link, r.quality or 1, r.minLevel or 0,
           r.type or "Trade Goods", r.subType or "Cloth",
           r.stackCount or 20, r.equipLoc or "", r.texture or "icon"
end

-- ---------------------------------------------------------------------------
-- Bags
-- ---------------------------------------------------------------------------

-- Just enough of the container API for core/sell.lua's bag walks.
--
-- W.SetBags takes { [bagIndex] = { {link=, count=, texture=}, ... } }, the
-- inner array indexed by SLOT. Bag 0 is the backpack, as on the real client.
--
-- sell.IsAuctionable reads a scanning tooltip, and the stub tooltip reports
-- zero lines -- so everything here counts as auctionable, which is what these
-- tests want. A soulbound case would need tooltip lines, not bag entries.
W.bags = {}

-- Establishing a fresh set of bags also empties the cursor and the sell slot.
--
-- Without that, an item still held from a previous case gets put BACK into
-- the new bags when something clears the slot -- so five copper bars become
-- ten and the test reads as a duplication bug in the addon rather than as one
-- world leaking into the next.
function W.SetBags(t)
    W.bags     = t or {}
    W.cursor   = nil
    W.sellSlot = nil
end

function GetContainerNumSlots(bag)
    local b = W.bags[bag]
    return b and table.getn(b) or 0
end

function GetContainerItemLink(bag, slot)
    local b = W.bags[bag]
    local s = b and b[slot]
    return s and s.link or nil
end

function GetContainerItemInfo(bag, slot)
    local b = W.bags[bag]
    local s = b and b[slot]
    if not s or not s.link then return nil end
    return s.texture or "icon", s.count or 1
end

-- ---------------------------------------------------------------------------
-- The cursor and the auction sell slot
-- ---------------------------------------------------------------------------
--
-- MODELLED, not stubbed, because the bug this exists for is a property of how
-- the client MOVES items: ClickAuctionSellItemButton SWAPS the cursor with
-- whatever is already in the sell slot. Place an item while the slot is
-- occupied and the old one comes back onto the cursor -- where it silently
-- stays until something puts it down.
--
-- A no-op stub would have made the fix untestable and the bug unreproducible,
-- which is how it stayed a guess for one whole release.
--
-- An emptied bag slot keeps its place in the array as a table with no link,
-- so GetContainerNumSlots (which is table.getn) does not change when an item
-- leaves a bag.
W.cursor   = nil    -- { link, count, bag, slot } or nil
W.sellSlot = nil    -- { link, count, bag, slot } or nil

local function bagCell(bag, slot)
    local b = W.bags[bag]
    if not b then return nil end
    if not b[slot] then b[slot] = {} end
    return b[slot]
end

function PickupContainerItem(bag, slot)
    local cell = bagCell(bag, slot)
    if not cell then return end
    local held = W.cursor
    if cell.link then
        W.cursor = { link = cell.link, count = cell.count or 1,
                     bag = bag, slot = slot }
    else
        W.cursor = nil
    end
    cell.link  = held and held.link or nil
    cell.count = held and held.count or nil
end

function ClickAuctionSellItemButton()
    local held, slotted = W.cursor, W.sellSlot
    W.sellSlot = held
    W.cursor   = slotted
end

-- Puts a held item back where it came from, which is what the real client
-- does: the cursor is never simply emptied of a real item.
function ClearCursor()
    local held = W.cursor
    W.cursor = nil
    if not held then return end
    local cell = bagCell(held.bag, held.slot)
    if cell and not cell.link then
        cell.link, cell.count = held.link, held.count
        return
    end
    -- Its origin is occupied: drop it in the first free slot, as the client
    -- would. If there is nowhere at all it stays put, which is a full-bags
    -- case rather than a lost item.
    for bag = 0, 4 do
        local b = W.bags[bag]
        for i = 1, table.getn(b or {}) do
            if not b[i].link then
                b[i].link, b[i].count = held.link, held.count
                return
            end
        end
    end
    W.cursor = held
end

function GetAuctionSellItemInfo()
    local s = W.sellSlot
    if not s then return nil end
    local rec = W.items[s.link] or {}
    return rec.name or s.link, rec.texture or "icon", s.count or 1,
           rec.quality or 1, 1, rec.sellPrice or 0,
           rec.stackCount or 20, s.link
end

-- ---------------------------------------------------------------------------
-- Auction house
-- ---------------------------------------------------------------------------

W.page          = {}        -- array of listing records for the current page
W.totalAuctions = 0
W.queries       = {}        -- every QueryAuctionItems call, for assertions
W.queryOpen     = true      -- what CanSendAuctionQuery reports
W.bids          = {}        -- every PlaceAuctionBid call
W.strictArgs    = true      -- assert the 1.12 signatures

function W.SetPage(rows, totalAuctions)
    W.page = rows or {}
    W.totalAuctions = totalAuctions or table.getn(W.page)
end

function GetNumAuctionItems(list)
    if list ~= "list" then return 0, 0 end
    return table.getn(W.page), W.totalAuctions
end

-- EXACTLY the 1.12 twelve, in order. `owner` is nil until the name resolves,
-- and rows may say so by setting ownerUnresolved.
function GetAuctionItemInfo(list, i)
    if list ~= "list" then return nil end
    local r = W.page[i]
    if not r then return nil end
    local owner = r.owner
    if r.ownerUnresolved then owner = nil end
    return r.name, r.texture or "icon", r.count or 1, r.quality or 1,
           r.canUse, r.level or 1, r.minBid or 0, r.minIncrement or 0,
           r.buyout or 0, r.bidAmount or 0, r.highBidder, owner
end

function GetAuctionItemLink(list, i)
    local r = (list == "list") and W.page[i]
    return r and r.link or nil
end

-- 1-4 on 1.12, indexing AUCTION_TIME_LEFT1..4. Never a string.
function GetAuctionItemTimeLeft(list, i)
    local r = (list == "list") and W.page[i]
    return r and (r.timeLeft or 4) or nil
end

function CanSendAuctionQuery() return W.queryOpen end

function QueryAuctionItems(name, minLevel, maxLevel, invType,
                           class, subclass, page, isUsable, quality)
    if W.strictArgs then
        -- The stock browse UI sends GetText() results, so these are ALWAYS
        -- strings; servers may silently ignore a query with nils in these
        -- slots, which presents as a scan that spins forever.
        assert(type(name) == "string",
               "QueryAuctionItems: name must be a string, got "
               .. type(name))
        assert(type(minLevel) == "string",
               "QueryAuctionItems: minLevel must be a string, got "
               .. type(minLevel))
        assert(type(maxLevel) == "string",
               "QueryAuctionItems: maxLevel must be a string, got "
               .. type(maxLevel))
        assert(page == nil or (type(page) == "number" and page >= 0),
               "QueryAuctionItems: page is 0-indexed, got " .. tostring(page))

        -- The index and flag args are NUMBERS or nil. Never booleans.
        -- v1.21.0 sent `isUsable = true` and the Usable check box did
        -- nothing: 1.12 CheckButtons report 1/nil and the stock browse UI
        -- passes GetChecked() straight into that slot, so a Lua boolean is a
        -- shape the client is never handed. It is legal Lua, the query still
        -- goes out, and the only symptom is a filter that quietly does not
        -- apply -- which is exactly the kind of fault this file exists to
        -- catch, and did not.
        local flags = { invType = invType, class = class,
                        subclass = subclass, quality = quality }
        for key, v in pairs(flags) do
            assert(v == nil or type(v) == "number",
                   "QueryAuctionItems: " .. key .. " must be a number or nil, "
                   .. "got " .. type(v) .. " (" .. tostring(v) .. ")")
        end

        -- isUsable is tighter: 1 or nil, the only two values GetChecked()
        -- produces. 0 is refused ON PURPOSE -- 0 is TRUTHY in Lua, so a
        -- client reading this slot as a flag would take it as "usable only"
        -- and silently narrow every search. nil is the only safe "off".
        assert(isUsable == nil or isUsable == 1,
               "QueryAuctionItems: isUsable must be 1 or nil (0 is TRUTHY in "
               .. "Lua and would read as 'on'), got " .. type(isUsable)
               .. " (" .. tostring(isUsable) .. ")")
    end
    table.insert(W.queries, {
        name = name, minLevel = minLevel, maxLevel = maxLevel,
        invType = invType, class = class, subclass = subclass,
        page = page, isUsable = isUsable, quality = quality,
    })
    W.queryOpen = false          -- the client shuts the gate after a query
end

function PlaceAuctionBid(list, index, amount)
    table.insert(W.bids, { list = list, index = index, amount = amount })
end

function GetAuctionItemClasses() return "Weapon", "Armor", "Trade Goods" end
function GetAuctionItemSubClasses() return "Cloth", "Leather" end

-- ---------------------------------------------------------------------------
-- Reset
-- ---------------------------------------------------------------------------

-- Between suites. Anything a test mutated goes back to a known state, so an
-- ordering change cannot turn a passing suite into a failing one.
function W.Reset()
    W.messages      = {}
    W.page          = {}
    W.totalAuctions = 0
    W.queries       = {}
    W.queryOpen     = true
    W.bids          = {}
    W.items         = {}
    W.bags          = {}
    W.cursor        = nil
    W.sellSlot      = nil
    W.tooltipLines  = {}
    W.money         = 500000
    W.now           = 1700000000
    W.uptime        = 1000
    W.spellTargeting = false
    W.loot          = {}
    W.equipped      = {}
    W.itemInfoShape = "vanilla"
    C_Item          = nil
    AegisExchangeDB     = nil
    AegisExchangeCharDB = nil
end

-- Load the addon's core modules in .toc order under this simulated client.
-- `upTo` stops early, e.g. W.LoadCore("util") for the pure-Lua layer only.
function W.LoadCore(upTo)
    local order = { "init", "util", "db", "itemlevel", "disenchant",
                    "scan", "sell", "buy" }
    -- This list is a SECOND copy of the .toc's load order, and two copies of
    -- one order is how a file gets added to the addon but never to the tests
    -- -- which presents as "the suite passes and the client errors". Read the
    -- .toc and refuse to run if they have drifted.
    local toc, i = io.open("Aegis_Exchange.toc"), 1
    if toc then
        for line in toc:lines() do
            local _, _, name = string.find(line, "^core\\(%a+)%.lua")
            if name then
                if order[i] ~= name then
                    error("tests/support/wow.lua load order has drifted from"
                        .. " Aegis_Exchange.toc: expected '" .. name
                        .. "' at position " .. i .. ", found '"
                        .. tostring(order[i]) .. "'")
                end
                i = i + 1
            end
        end
        toc:close()
        if i - 1 ~= table.getn(order) then
            error("tests/support/wow.lua lists " .. table.getn(order)
                .. " core files, Aegis_Exchange.toc lists " .. (i - 1))
        end
    end
    for i = 1, table.getn(order) do
        dofile("core/" .. order[i] .. ".lua")
        if order[i] == upTo then break end
    end
    return AegisExchange
end

-- ---------------------------------------------------------------------------
-- Clock, spell targeting, loot
-- ---------------------------------------------------------------------------

-- A clock the test drives, so a time WINDOW can actually be tested rather
-- than assumed. Real GetTime is seconds since LOGIN, and is a different clock
-- from time()'s epoch seconds -- kept separate here for that reason, and
-- because advancing one to test a timeout must not silently move the calendar
-- the price DB buckets its dailies by.
W.uptime = 1000
function GetTime() return W.uptime end
function W.Advance(seconds) W.uptime = W.uptime + seconds end

-- True while a spell is waiting for the player to click an item -- what
-- Disenchant, Enchant and Pick Lock all do. This is the signal that separates
-- "clicked a bag item" from "clicked a bag item AT something".
W.spellTargeting = false
function SpellIsTargeting() return W.spellTargeting end

-- The open loot window: { { link = , quantity = , money = } , ... }
W.loot = {}
function W.SetLoot(rows) W.loot = rows or {} end

function GetNumLootItems() return table.getn(W.loot) end
function LootSlotIsItem(i)
    local r = W.loot[i]
    return (r and not r.money) and 1 or nil
end
function GetLootSlotLink(i)
    local r = W.loot[i]
    return r and r.link or nil
end
function GetLootSlotInfo(i)
    local r = W.loot[i]
    if not r then return nil end
    return "icon", r.name or "loot", r.quantity or 1, r.quality or 1, nil
end

function GetInventoryItemLink(unit, slot)
    local r = W.equipped and W.equipped[slot]
    return r and r.link or nil
end
W.equipped = {}

-- ---------------------------------------------------------------------------
-- C_Item: the data 1.12 has and never shows
-- ---------------------------------------------------------------------------

-- A client mod (ClassicAPI) exposes an item's vendor sell price and its item
-- level -- both of which the client fills in on every item and displays for
-- neither. Aegis must work with it and WITHOUT it, so the harness has to be
-- able to take it away again: `W.SetClientItemData(false)` removes the global
-- entirely, which is the state of every client that has no such mod.
function W.SetClientItemData(on)
    if not on then C_Item = nil return end
    C_Item = {
        GetItemSellPriceByID = function(id)
            local r = W.items[id]
            return r and r.sellPrice or nil
        end,
        GetDetailedItemLevelInfo = function(id)
            local r = W.items[id]
            return r and r.itemLevel or nil
        end,
    }
end

-- Load a ui/ module on top of the core ones.
--
-- Kept separate from W.LoadCore because most suites want nothing to do with
-- the UI, and ui/frame.lua in particular builds a window on load. The files
-- reachable this way are the ones that only DEFINE things at file scope.
function W.LoadUI(name)
    dofile("ui/" .. name .. ".lua")
    return AegisExchange
end

-- Drive ADDON_LOADED for our addon, which is the ONLY point at which
-- SavedVariables exist and A.OnLoad callbacks may run.
function W.FireAddonLoaded(A)
    AegisExchangeDB     = AegisExchangeDB or {}
    AegisExchangeCharDB = AegisExchangeCharDB or {}
    W.FireEvent(A.frame, "ADDON_LOADED", A.name)
end

return W
