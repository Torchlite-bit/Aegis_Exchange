-- Aegis: Exchange
-- core/sell.lua
--
-- Posting engine: wraps the 1.12 create-auction API (each call verified against
-- the Turtle UI source) and layers Aegis price context + Turtle specifics on
-- top. The UI lives in ui/frame.lua's Sell tab, exactly as the scanner engine
-- (core/scan.lua) is driven from the Scan tab.
--
-- 1.12 API used here (all globals, valid while the AH SESSION is open —
-- independent of whether the Blizzard AuctionFrame is shown):
--   ClickAuctionSellItemButton()       -- move the cursor item into the sell slot
--   GetAuctionSellItemInfo()           -> name, texture, count, quality, canUse,
--                                         price, maxStack, link   (8 values)
--   CalculateAuctionDeposit(minutes)   -- client deposit math for the slot item
--   StartAuction(minBid, buyout, mins) -- COPPER for the WHOLE stack in the slot;
--                                         mins is 120 / 480 / 1440
--   GetNumAuctionItems("owner")        -> batch, total (total = your auctions)
--
-- Turtle specifics (CLAUDE.md): durations are x3, so 120/480/1440 minutes are
-- really 6h / 24h / 72h; 120-auction account cap; 5% consignment cut on sales;
-- and the shown deposit is inflated -- we scale it by ~0.6 and ALWAYS label it
-- "approx", never exact.

local A = AegisExchange
A.sell = {}
local sell = A.sell
local util = A.util

-- Duration options. `minutes` is what the client / StartAuction expects;
-- `label` is the Turtle-real time (x3) we actually SHOW.
sell.DURATIONS = {
    { minutes = 120,  label = "6h"  },
    { minutes = 480,  label = "24h" },
    { minutes = 1440, label = "72h" },
}
sell.DEFAULT_DURATION = 480   -- 24h, matching the stock UI's default radio

sell.CAP = 120     -- Turtle account-wide auction cap
sell.CUT = 0.05    -- 5% consignment cut taken on a sale

-- Turtle's shown deposit is inflated relative to what actually gets charged;
-- scale by this to approximate. The result is ALWAYS presented as "approx".
sell.TURTLE_DEPOSIT_FACTOR = 0.6

-- ---------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------

-- Normalized view of the item currently in the sell slot, or nil if empty.
function sell.GetItem()
    local name, texture, count, quality, canUse, price, maxStack, link =
        GetAuctionSellItemInfo()
    if not name then return nil end
    count = count or 1
    return {
        name     = name,
        texture  = texture,
        count    = count,
        quality  = quality,
        canUse   = canUse,
        price    = price or 0,          -- vendor deposit-base for the whole stack
        maxStack = maxStack or count,
        link     = link,
        itemId   = link and util.ItemIdFromLink(link) or nil,
    }
end

-- Your current number of active auctions (second return of GetNumAuctionItems).
function sell.OwnerCount()
    local _, total = GetNumAuctionItems("owner")
    return total or 0
end

function sell.AtCap()
    return sell.OwnerCount() >= sell.CAP
end

-- Approximate deposit (copper) for the slotted item at `minutes`. Prefers the
-- client's own CalculateAuctionDeposit (present once the AH UI has loaded),
-- scaled by the Turtle factor. Returns (copper, isApprox); isApprox is true on
-- Turtle so the UI can label it honestly.
function sell.EstimateDeposit(minutes)
    if not minutes or minutes <= 0 then return 0, true end
    local base
    if CalculateAuctionDeposit then
        base = CalculateAuctionDeposit(minutes)
    else
        -- Fallback: the vanilla formula, from the slot item directly.
        local it = sell.GetItem()
        if not it then return 0, true end
        base = math.floor(it.price * (minutes / 120)
            * (1 + (it.maxStack - it.count) * 0.05) * 0.025)
    end
    base = base or 0
    if A.isTurtle then
        return math.floor(base * sell.TURTLE_DEPOSIT_FACTOR), true
    end
    return base, false
end

-- Suggested per-unit prices for `itemId` from the price DB (any may be nil).
function sell.Suggest(itemId)
    if not itemId then return nil end
    return {
        market    = A.db.MarketValue(itemId),
        minBuyout = A.db.MinBuyout(itemId),
        vendor    = A.db.GetVendor(itemId),
    }
end

-- Per-unit price to undercut the cheapest seen buyout by ~5% (falls back to
-- market value). Returns copper, or nil if we have no data for the item.
function sell.UndercutUnit(itemId)
    -- Prefer the freshest thing we have: the lowest OTHER seller from the last
    -- item scan, undercut by 1 copper; else the DB's min buyout / market -5%.
    local low = sell.LowestListingUnit(true)
    if low and low > 1 then
        return low - 1
    end
    local s = sell.Suggest(itemId)
    if not s then return nil end
    local base = s.minBuyout or s.market
    if not base then return nil end
    local under = math.floor(base * 0.95)
    if under < 1 then under = 1 end
    return under
end

-- ---------------------------------------------------------------------------
-- Per-item listing scan (drives the Sell tab's price table)
-- ---------------------------------------------------------------------------

sell.listings   = nil   -- raw rows from the last item scan (sorted cheapest 1st)
sell.scanItemId = nil   -- item those rows are for
sell.scanName   = nil
sell.scanWhen   = nil    -- epoch of the last completed item scan

-- Lowest per-unit buyout among the last scan's listings. `excludeMine` skips
-- your own auctions (so undercut targets other sellers). Returns nil if none.
function sell.LowestListingUnit(excludeMine)
    if not sell.listings then return nil end
    local best = nil
    local i = 1
    while i <= table.getn(sell.listings) do
        local r = sell.listings[i]
        if r.unit and r.unit > 0 and not (excludeMine and r.isMine) then
            if not best or r.unit < best then best = r.unit end
        end
        i = i + 1
    end
    return best
end

-- Scan the AH for every listing of one item (by name), keeping only exact
-- itemId matches (a name query is a substring search on 1.12). Collects rows
-- {count, buyout, unit, minBid, owner, isMine}, sorts cheapest-first, and calls
-- onDone(rows). onProgress(page, total) fires per page. Returns false if the
-- scanner is busy with another scan.
function sell.ScanItem(itemName, itemId, onProgress, onDone)
    if A.scan.IsRunning() or A.scan.IsPaused() then
        return false
    end
    sell.listings   = {}
    sell.scanItemId = itemId
    sell.scanName   = itemName
    local me = UnitName("player")
    A.scan.Start({ name = itemName }, {
        onListing = function(id, name, count, buyout, minBid, owner)
            if id == itemId then
                table.insert(sell.listings, {
                    count  = count,
                    buyout = buyout,   -- stack buyout (copper); 0 = bid only
                    unit   = (buyout > 0) and math.floor(buyout / count) or nil,
                    minBid = minBid,
                    owner  = owner,
                    isMine = (owner and me and owner == me) and true or false,
                })
            end
        end,
        onPage = onProgress,
        stampLast = false,   -- price lookup; don't reset the "last full scan"
        onComplete = function()
            table.sort(sell.listings, function(a, b)
                local au = a.unit or a.buyout or 1e18
                local bu = b.unit or b.buyout or 1e18
                return au < bu
            end)
            sell.scanWhen = time()
            if onDone then onDone(sell.listings) end
        end,
    })
    return true
end

-- Collapse listings into display groups keyed by (unit price, stack size),
-- preserving the cheapest-first order. Each group: {unit, count, buyout, num,
-- mine, pct} where num = how many such auctions and pct = % of market value.
function sell.GroupListings(rows, marketValue)
    local order = {}
    local byKey = {}
    local i = 1
    while i <= table.getn(rows) do
        local r = rows[i]
        local key = tostring(r.unit or 0) .. ":" .. tostring(r.count)
        local g = byKey[key]
        if not g then
            g = { unit = r.unit, count = r.count, buyout = r.buyout,
                  num = 0, mine = false }
            if marketValue and marketValue > 0 and r.unit then
                g.pct = math.floor(r.unit / marketValue * 100)
            end
            byKey[key] = g
            table.insert(order, g)
        end
        g.num = g.num + 1
        if r.isMine then g.mine = true end
        i = i + 1
    end
    return order
end

-- How a per-unit price compares to the item's vendor sell price. Returns
-- { vendor, pct, above, mult } or nil when we have no vendor data.
function sell.VendorCompare(itemId, unitPrice)
    local vendor = A.db.GetVendor(itemId)
    if not vendor or vendor <= 0 or not unitPrice or unitPrice <= 0 then
        return nil
    end
    return {
        vendor = vendor,
        pct    = math.floor(unitPrice / vendor * 100),
        mult   = unitPrice / vendor,
        above  = unitPrice >= vendor,
    }
end

-- ---------------------------------------------------------------------------
-- Bag enumeration (drives the Sell tab's "Your Bags" list)
-- ---------------------------------------------------------------------------

-- Walk bags 0..4 and group every item by its category (GetItemInfo's itemType).
-- Returns an ordered list of { name = className, items = { entry, ... } } where
-- entry = { bag, slot, itemId, name, texture, count }. Order follows first
-- appearance so the grouping is stable between refreshes.
function sell.ScanBags()
    local order = {}
    local byCat = {}
    local bag = 0
    while bag <= 4 do
        local slots = GetContainerNumSlots(bag) or 0
        local slot = 1
        while slot <= slots do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local texture, count = GetContainerItemInfo(bag, slot)
                local iname, _, _, _, _, itype = GetItemInfo(link)
                local cname = itype or "Other"
                local cat = byCat[cname]
                if not cat then
                    cat = { name = cname, items = {} }
                    byCat[cname] = cat
                    table.insert(order, cat)
                end
                table.insert(cat.items, {
                    bag     = bag,
                    slot    = slot,
                    itemId  = util.ItemIdFromLink(link),
                    name    = iname or link,
                    texture = texture,
                    count   = count or 1,
                })
            end
            slot = slot + 1
        end
        bag = bag + 1
    end
    return order
end

-- Put the item at (bag, slot) into the auction sell slot. Clears the cursor
-- first so we never swap something already held.
function sell.PlaceFromBag(bag, slot)
    ClearCursor()
    PickupContainerItem(bag, slot)
    ClickAuctionSellItemButton()
end

-- ---------------------------------------------------------------------------
-- Posting
-- ---------------------------------------------------------------------------

-- Post the item currently in the slot. `unitBuyout` / `unitStart` are per-unit
-- copper (the whole stack is auctioned; totals are unit * count). `minutes` is
-- 120 / 480 / 1440. Returns (true) once the auction is fired, or (false,
-- reason) on a validation failure. Success is otherwise confirmed by the
-- follow-up NEW_AUCTION_UPDATE / AUCTION_OWNED_LIST_UPDATE events.
function sell.Post(unitBuyout, unitStart, minutes)
    local it = sell.GetItem()
    if not it then return false, "No item in the sell slot." end
    if sell.AtCap() then
        return false, "You are at the " .. sell.CAP .. "-auction cap."
    end
    if not minutes or minutes <= 0 then
        return false, "Pick a duration."
    end
    local count  = it.count
    local buyout = math.floor((unitBuyout or 0) * count)
    -- Start bid defaults to the buyout when left blank.
    local start  = math.floor((unitStart or unitBuyout or 0) * count)
    if start < 1 then
        return false, "Enter a start bid or buyout of at least 1 copper."
    end
    if buyout > 0 and start > buyout then
        return false, "Start bid can't exceed the buyout."
    end
    StartAuction(start, buyout, minutes)
    return true
end
