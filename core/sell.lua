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

-- ---------------------------------------------------------------------------
-- Owned auctions (Auctions tab): read + cancel
-- ---------------------------------------------------------------------------

-- 1.12 time-left codes -> short labels. Turtle multiplies real durations x3, so
-- these buckets are wider in wall-clock time, but the codes are unchanged.
local TIME_LEFT = { "< 30m", "< 2h", "< 12h", "> 12h" }
function sell.TimeLeftText(code)
    return code and TIME_LEFT[code] or "\226\128\148"
end

-- Ask the server to (re)send your auction list. Fires AUCTION_OWNED_LIST_UPDATE
-- when it lands. Optional on some clients, so it's guarded.
--
-- The resulting event ALSO reaches Blizzard's own auction UI, whose
-- AuctionFrameAuctions_Update() does arithmetic on AuctionFrameAuctions.page.
-- We replace the stock AH window, so its Auctions tab may never have been
-- shown and that field can still be nil -- which threw
--   Blizzard_AuctionUI.lua:836: attempt to perform arithmetic on field 'page'
-- Seed it (harmless: 0 is exactly what their OnShow sets) before asking.
function sell.RequestOwnerAuctions()
    if AuctionFrameAuctions and AuctionFrameAuctions.page == nil then
        AuctionFrameAuctions.page = 0
    end
    if GetOwnerAuctionItems then GetOwnerAuctionItems(0) end
end

-- Read your active auctions from the "owner" list into plain rows. Bid/buyout
-- are per WHOLE stack (as the API reports); unit is derived for undercut checks.
function sell.OwnerAuctions()
    local rows = {}
    local n = GetNumAuctionItems("owner")
    local i = 1
    while i <= (n or 0) do
        local name, texture, count, quality, canUse, level, minBid, minInc,
              buyout, bidAmount, highBidder = GetAuctionItemInfo("owner", i)
        if name then
            count = count or 1
            local itemId
            if GetAuctionItemLink then
                itemId = util.ItemIdFromLink(GetAuctionItemLink("owner", i))
            end
            local timeLeft
            if GetAuctionItemTimeLeft then
                timeLeft = GetAuctionItemTimeLeft("owner", i)
            end
            table.insert(rows, {
                index      = i,
                name       = name,
                texture    = texture,
                count      = count,
                quality    = quality,
                buyout     = buyout or 0,
                unit       = (buyout and buyout > 0)
                             and math.floor(buyout / count) or nil,
                bid        = bidAmount or 0,
                minBid     = minBid or 0,
                hasBid     = (bidAmount and bidAmount > 0) and true or false,
                highBidder = highBidder,
                timeLeft   = timeLeft,
                itemId     = itemId,
            })
        end
        i = i + 1
    end
    return rows
end

-- Cancel the auction at owner index `i`. The refreshed list arrives via
-- AUCTION_OWNED_LIST_UPDATE.
function sell.CancelOwnerAuction(i)
    if not i or not CancelAuction then return false end
    CancelAuction(i)
    return true
end

-- ---------------------------------------------------------------------------
-- Vendor list: bag items worth MORE at a vendor than on the AH
-- ---------------------------------------------------------------------------

-- Compare each auctionable bag item's vendor price against what it would net
-- on the AH (best known unit price minus the 5% consignment cut). Returns rows
-- sorted by the biggest vendor advantage first:
--   { name, itemId, texture, count, vendorUnit, ahUnit, netAh, diff, total }
-- `diff` is per unit (vendor - net AH); `total` is diff x count. Items with no
-- recorded vendor price are skipped -- vendor prices come from hovering an
-- item at a merchant, so the list fills in as you play.
function sell.VendorList()
    local rows = {}
    local cats = sell.ScanBags()
    local ci = 1
    while ci <= table.getn(cats) do
        local items = cats[ci].items
        local ii = 1
        while ii <= table.getn(items) do
            local it = items[ii]
            local vendor = it.itemId and A.db.GetVendor(it.itemId)
            if vendor and vendor > 0 then
                -- Best AH unit price we know, after the consignment cut.
                local ah = A.db.MinBuyout(it.itemId) or A.db.MarketValue(it.itemId)
                local netAh = ah and math.floor(ah * (1 - sell.CUT)) or 0
                if vendor > netAh then
                    local diff = vendor - netAh
                    table.insert(rows, {
                        name       = it.name,
                        itemId     = it.itemId,
                        texture    = it.texture,
                        count      = it.count or 1,
                        vendorUnit = vendor,
                        ahUnit     = ah,
                        netAh      = netAh,
                        diff       = diff,
                        total      = diff * (it.count or 1),
                    })
                end
            end
            ii = ii + 1
        end
        ci = ci + 1
    end
    table.sort(rows, function(a, b) return a.total > b.total end)
    return rows
end

-- Bag stacks whose item is marked for vendoring. Rows are
-- { bag, slot, itemId, name, count, vendorUnit, value } — `value` is the
-- vendor payout for that whole stack, when we know the unit price.
function sell.MarkedInBags()
    local rows = {}
    local cats = sell.ScanBags()
    local ci = 1
    while ci <= table.getn(cats) do
        local items = cats[ci].items
        local ii = 1
        while ii <= table.getn(items) do
            local it = items[ii]
            if it.itemId and A.db.IsVendorMarked(it.itemId) then
                local unit = A.db.GetVendor(it.itemId)
                table.insert(rows, {
                    bag = it.bag, slot = it.slot, itemId = it.itemId,
                    name = it.name, count = it.count or 1,
                    vendorUnit = unit,
                    value = unit and unit * (it.count or 1) or nil,
                })
            end
            ii = ii + 1
        end
        ci = ci + 1
    end
    return rows
end

-- Sell every marked bag stack to the open merchant. On 1.12 that is
-- UseContainerItem(bag, slot) while the merchant window is up. Returns
-- (stacksSold, estimatedCopper). Caller must confirm first -- this spends
-- items. Refuses unless a merchant window is actually open.
function sell.SellMarkedToVendor()
    if not (MerchantFrame and MerchantFrame:IsVisible()) then
        return 0, 0
    end
    if not UseContainerItem then return 0, 0 end
    local rows = sell.MarkedInBags()
    -- Sell from the LAST slot backwards: selling shifts nothing on 1.12, but
    -- reverse order keeps our captured bag/slot pairs valid if it ever does.
    local sold, value = 0, 0
    local i = table.getn(rows)
    while i >= 1 do
        local r = rows[i]
        UseContainerItem(r.bag, r.slot)
        sold = sold + 1
        value = value + (r.value or 0)
        i = i - 1
    end
    return sold, value
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

-- Undercut a reference price by the user's configured rule (Aegis tab): either
-- a percent below, or a fixed copper amount below. Always lands at least 1
-- copper under. Defaults to 5%.
local function ApplyUndercut(ref)
    if not ref or ref <= 1 then return ref end
    local mode = A.db and A.db.Setting and A.db.Setting("undercutMode") or "pct"
    local under
    if mode == "flat" then
        local amt = A.db.Setting("undercutAmount") or 100
        if amt < 1 then amt = 1 end
        under = ref - amt
    else
        local pct = A.db.Setting("undercutPct") or 5
        if pct < 0 then pct = 5 end
        under = math.floor(ref * (1 - pct / 100))
    end
    if under >= ref then under = ref - 1 end   -- guarantee a real undercut
    if under < 1 then under = 1 end
    return under
end

-- Per-unit price to undercut the cheapest seen buyout (falls back to market
-- value). Returns copper, or nil if we have no data for the item.
function sell.UndercutUnit(itemId)
    -- Prefer the freshest thing we have: the lowest OTHER seller from the last
    -- item scan; else the DB's min buyout / market. Both get the same percent.
    local low = sell.LowestListingUnit(true)
    if low and low > 1 then
        return ApplyUndercut(low)
    end
    local s = sell.Suggest(itemId)
    if not s then return nil end
    local base = s.minBuyout or s.market
    if not base then return nil end
    return ApplyUndercut(base)
end

-- ---------------------------------------------------------------------------
-- Per-item listing scan (drives the Sell tab's price table)
-- ---------------------------------------------------------------------------

sell.listings   = nil   -- raw rows from the last item scan (sorted cheapest 1st)
sell.scanItemId = nil   -- item those rows are for
sell.scanName   = nil
sell.scanWhen   = nil   -- epoch of the last completed item scan

sell.cache      = {}    -- { [itemId] = { listings, when } }
sell.CACHE_TTL  = 3600   -- seconds a cached result stays valid

-- Batch "Scan All" state: iterates every bag item, scanning uncached ones one
-- at a time. The UI reads batchCurrentItemId to show a yellow * while the item
-- is being fetched.
sell.batchActive        = false
sell.batchCurrentItemId = nil
sell.batchQueue         = nil
sell.batchIndex         = 1

-- Walk every auctionable bag item and scan the AH for it, skipping items that
-- already have a fresh cache entry. onItemDone(itemId) fires after EACH item
-- is processed (cache hit or scan complete); onAllDone() fires when the queue
-- is exhausted or the batch is stopped.
function sell.ScanAllBags(onItemDone, onAllDone)
    -- Build a flat queue from the bag categories.
    local cats = sell.ScanBags()
    local queue = {}
    local ci = 1
    while ci <= table.getn(cats) do
        local items = cats[ci].items
        local ii = 1
        while ii <= table.getn(items) do
            table.insert(queue, items[ii])
            ii = ii + 1
        end
        ci = ci + 1
    end
    sell.batchQueue  = queue
    sell.batchIndex  = 1
    sell.batchActive = true

    local function processNext()
        if not sell.batchActive then
            sell.batchCurrentItemId = nil
            if onAllDone then onAllDone() end
            return
        end
        local idx = sell.batchIndex
        if idx > table.getn(queue) then
            sell.batchActive = false
            sell.batchCurrentItemId = nil
            if onAllDone then onAllDone() end
            return
        end
        local item = queue[idx]
        sell.batchIndex = idx + 1
        sell.batchCurrentItemId = item.itemId

        -- Already cached? Fire the per-item callback immediately (the UI just
        -- needs to redraw the green dot) and move on.
        local entry = sell.cache[item.itemId]
        if entry and time() - entry.when < sell.CACHE_TTL then
            if onItemDone then onItemDone(item.itemId) end
            processNext()
            return
        end

        -- Not cached: run a targeted AH scan for this item. Reuse sell.ScanItem
        -- which handles the query, filtering, sorting, and deep-copy caching.
        sell.ScanItem(item.name, item.itemId, nil, function()
            if onItemDone then onItemDone(item.itemId) end
            processNext()
        end)
    end

    processNext()
end

-- Abort a running batch scan. The current item's scan will still finish (it is
-- already in flight), but no further items will be queued.
function sell.StopBatchScan()
    sell.batchActive = false
    sell.batchCurrentItemId = nil
end

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
    -- Cache hit: return stored results without a new scan.
    local entry = sell.cache[itemId]
    if entry and time() - entry.when < sell.CACHE_TTL then
        sell.listings   = entry.listings
        sell.scanItemId = itemId
        sell.scanName   = itemName
        sell.scanWhen   = entry.when
        if onDone then onDone(sell.listings) end
        return true
    end
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
            -- Store a deep copy in the cache so later mutations to sell.listings
            -- don't corrupt the cached data.
            local copy = {}
            local li = 1
            while li <= table.getn(sell.listings) do
                local r = sell.listings[li]
                table.insert(copy, {
                    count  = r.count,
                    buyout = r.buyout,
                    unit   = r.unit,
                    minBid = r.minBid,
                    owner  = r.owner,
                    isMine = r.isMine,
                })
                li = li + 1
            end
            sell.cache[itemId] = { listings = copy, when = sell.scanWhen }
            -- Temporary debug: log what's being cached so we can trace
            -- the root cause of cache entries with 0 rows.
            if DEFAULT_CHAT_FRAME then
                DEFAULT_CHAT_FRAME:AddMessage(
                    "|cff5fc8f8Aegis cache store:|r "
                    .. tostring(itemName) .. " (id:" .. tostring(itemId)
                    .. ") rows=" .. tostring(table.getn(copy)))
            end
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

-- Tooltip phrases that mark an item you cannot put on the auction house. 1.12
-- exposes no soulbound flag, so we read the item's tooltip text (the same trick
-- aux / Auctionator use). Globals fall back to English literals off Turtle.
local BLOCK_PHRASES = {
    ITEM_SOULBOUND  or "Soulbound",
    ITEM_BIND_QUEST or "Quest Item",
    ITEM_CONJURED   or "Conjured Item",
}

-- Hidden tooltip we own, created lazily, for reading bind status.
local function ScanTip()
    if not sell._scanTip then
        sell._scanTip = CreateFrame("GameTooltip", "AegisExchangeScanTooltip",
            nil, "GameTooltipTemplate")
    end
    return sell._scanTip
end

-- True unless the bag item is soulbound / quest / conjured (i.e. postable).
function sell.IsAuctionable(bag, slot)
    local tip = ScanTip()
    tip:SetOwner(UIParent, "ANCHOR_NONE")
    tip:ClearLines()
    tip:SetBagItem(bag, slot)
    local n = tip:NumLines() or 0
    local i = 2   -- line 1 is the item name; bind text sits below it
    while i <= n do
        local fs = getglobal("AegisExchangeScanTooltipTextLeft" .. i)
        local txt = fs and fs:GetText()
        if txt then
            local b = 1
            while b <= table.getn(BLOCK_PHRASES) do
                if string.find(txt, BLOCK_PHRASES[b], 1, true) then
                    return false
                end
                b = b + 1
            end
        end
        i = i + 1
    end
    return true
end

-- Walk bags 0..4 and group every POSTABLE item by its category (GetItemInfo's
-- itemType). Soulbound / quest / conjured items are skipped. Returns an ordered
-- list of { name = className, items = { entry, ... } } where entry =
-- { bag, slot, itemId, name, texture, count }. Order follows first appearance
-- so the grouping is stable between refreshes.
function sell.ScanBags()
    local order = {}
    local byCat = {}
    local bag = 0
    while bag <= 4 do
        local slots = GetContainerNumSlots(bag) or 0
        local slot = 1
        while slot <= slots do
            local link = GetContainerItemLink(bag, slot)
            if link and sell.IsAuctionable(bag, slot) then
                local texture, count = GetContainerItemInfo(bag, slot)
                local iname, _, _, _, _, itype = GetItemInfo(link)
                -- On 1.12 GetItemInfo may return nil until the client-side
                -- item cache is warm. Fall back to the name between [...] in
                -- the link so AH queries don't send a raw item-link string
                -- (which the server won't understand and would return 0
                -- results for, storing a bogus empty cache).
                if not iname then
                    local _, _, n = string.find(link, "%[([^%]]+)%]")
                    iname = n
                end
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

-- Where does `itemId` live in the bags RIGHT NOW? Returns (bag, slot) for the
-- largest auctionable stack, or nil.
--
-- Bag positions shift as you post, so any bag/slot captured earlier can be
-- stale (that slot may now be empty or hold something else). Anything acting on
-- a remembered item -- the post-scan sell queue especially -- must re-locate it
-- through here rather than trusting the old coordinates.
function sell.FindItemSlot(itemId)
    if not itemId then return nil end
    local bestBag, bestSlot, bestCount = nil, nil, 0
    local bag = 0
    while bag <= 4 do
        local slots = GetContainerNumSlots(bag) or 0
        local slot = 1
        while slot <= slots do
            local link = GetContainerItemLink(bag, slot)
            if link and util.ItemIdFromLink(link) == itemId
                and sell.IsAuctionable(bag, slot) then
                local _, count = GetContainerItemInfo(bag, slot)
                if (count or 0) > bestCount then
                    bestBag, bestSlot, bestCount = bag, slot, count or 0
                end
            end
            slot = slot + 1
        end
        bag = bag + 1
    end
    return bestBag, bestSlot
end

-- Place `itemId` into the sell slot, finding it fresh. Returns true if placed.
function sell.PlaceItemById(itemId)
    local bag, slot = sell.FindItemSlot(itemId)
    if not bag then return false end
    sell.PlaceFromBag(bag, slot)
    return true
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

-- ---------------------------------------------------------------------------
-- Multi-stack posting (post N stacks of a chosen size)
-- ---------------------------------------------------------------------------

-- Seconds between the two legs of a post (assemble a stack, then fire it) and
-- between consecutive posts, so the client settles and we never spam the server.
local ASSEMBLE_DELAY = 0.25
local POST_DELAY     = 0.45
local MAX_RETRIES    = 4
-- How long to wait for a split/pickup to actually reach the cursor before
-- treating the attempt as lost. SplitContainerItem needs a server round-trip on
-- 1.12, so this has to tolerate realm latency; the poll exits the instant the
-- cursor fills, so a fast realm never pays the full budget.
local CURSOR_TIMEOUT = 2.0

-- Total count of an item across all POSTABLE bag slots.
function sell.CountInBags(itemId)
    if not itemId then return 0 end
    local total = 0
    local bag = 0
    while bag <= 4 do
        local slots = GetContainerNumSlots(bag) or 0
        local slot = 1
        while slot <= slots do
            local link = GetContainerItemLink(bag, slot)
            if link and util.ItemIdFromLink(link) == itemId
                and sell.IsAuctionable(bag, slot) then
                local _, count = GetContainerItemInfo(bag, slot)
                total = total + (count or 0)
            end
            slot = slot + 1
        end
        bag = bag + 1
    end
    return total
end

-- How many stacks of `stackSize` we can actually assemble by splitting (each
-- split leaves the remainder in the same slot, so a slot of C yields
-- floor(C / stackSize) stacks). This is honest about fragmentation — we never
-- promise stacks we can't build without merging partials.
function sell.MaxStacks(itemId, stackSize)
    if not itemId or not stackSize or stackSize < 1 then return 0 end
    local n = 0
    local bag = 0
    while bag <= 4 do
        local slots = GetContainerNumSlots(bag) or 0
        local slot = 1
        while slot <= slots do
            local link = GetContainerItemLink(bag, slot)
            if link and util.ItemIdFromLink(link) == itemId
                and sell.IsAuctionable(bag, slot) then
                local _, count = GetContainerItemInfo(bag, slot)
                n = n + math.floor((count or 0) / stackSize)
            end
            slot = slot + 1
        end
        bag = bag + 1
    end
    return n
end

-- Per-stack deposit estimate for a stack of `stackSize`, from the item's vendor
-- unit price (nil if we have no vendor data). Turtle-scaled + approximate.
function sell.DepositFor(itemId, stackSize, minutes, maxStack)
    local vendorUnit = A.db.GetVendor(itemId)
    if not vendorUnit or vendorUnit <= 0 or not minutes or minutes <= 0 then
        return nil
    end
    maxStack = maxStack or stackSize
    local price = vendorUnit * stackSize
    local base = math.floor(price * (minutes / 120)
        * (1 + (maxStack - stackSize) * 0.05) * 0.025)
    if A.isTurtle then base = math.floor(base * sell.TURTLE_DEPOSIT_FACTOR) end
    return base
end

-- Trace the posting state machine. Shares the /aex debug flag with the scanner,
-- because "it says couldn't assemble a stack" is impossible to diagnose from
-- the outside -- this prints which phase gave up and what the slot actually
-- held.
function sell.Debug(msg)
    if A.debugScan and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff5fc8f8Aegis post:|r " .. msg)
    end
end

-- First postable bag slot holding at least `minCount` of the item, or nil.
local function FindStack(itemId, minCount)
    local bag = 0
    while bag <= 4 do
        local slots = GetContainerNumSlots(bag) or 0
        local slot = 1
        while slot <= slots do
            local link = GetContainerItemLink(bag, slot)
            if link and util.ItemIdFromLink(link) == itemId
                and sell.IsAuctionable(bag, slot) then
                local _, count = GetContainerItemInfo(bag, slot)
                if (count or 0) >= minCount then return bag, slot end
            end
            slot = slot + 1
        end
        bag = bag + 1
    end
    return nil
end

-- A bag slot holding EXACTLY `count` of the item. This is the stack the
-- assembler actually wants: the auction slot takes a whole bag stack reliably,
-- which is why posting always worked when the bag already held the right sizes.
local function FindExactStack(itemId, count)
    local bag = 0
    while bag <= 4 do
        local slots = GetContainerNumSlots(bag) or 0
        local slot = 1
        while slot <= slots do
            local link = GetContainerItemLink(bag, slot)
            if link and util.ItemIdFromLink(link) == itemId
                and sell.IsAuctionable(bag, slot) then
                local _, c = GetContainerItemInfo(bag, slot)
                if (c or 0) == count then return bag, slot end
            end
            slot = slot + 1
        end
        bag = bag + 1
    end
    return nil
end

-- Is this bag slot mid-move? GetContainerItemInfo's 3rd return is `locked`,
-- which the client sets while the server is still processing a move. Acting on
-- a locked slot is how a split silently does nothing -- so we wait instead of
-- burning a retry. (Technique noted from how aux paces its stack moves.)
local function SlotLocked(bag, slot)
    local _, _, locked = GetContainerItemInfo(bag, slot)
    return locked and true or false
end

-- First empty bag slot, for carving a split stack into. Backpack (0) last so we
-- prefer real bags and leave the backpack free for loot.
local function FindEmptySlot()
    local order = { 1, 2, 3, 4, 0 }
    local i = 1
    while i <= table.getn(order) do
        local bag = order[i]
        local slots = GetContainerNumSlots(bag) or 0
        local slot = 1
        while slot <= slots do
            if not GetContainerItemLink(bag, slot) then return bag, slot end
            slot = slot + 1
        end
        i = i + 1
    end
    return nil
end

-- Return any item sitting in the sell slot back to the bags (the Auctionator
-- clear pattern: pick it up, then ClearCursor drops it to its bag origin).
function sell.ClearSlot()
    if GetAuctionSellItemInfo() then
        ClickAuctionSellItemButton()
        ClearCursor()
    end
end

sell.job = nil   -- active multi-stack posting job

local function PostDriver()
    if not sell._postDriver then
        sell._postDriver = CreateFrame("Frame", "AegisExchangeSellDriver")
        sell._postDriver:Hide()
        sell._postDriver:SetScript("OnUpdate", function()
            sell.PostTick(arg1)
        end)
    end
    return sell._postDriver
end

local function FinishJob(reason)
    local job = sell.job
    sell.job = nil
    if sell._postDriver then sell._postDriver:Hide() end
    if job and job.callbacks and job.callbacks.onDone then
        job.callbacks.onDone(job.posted, job.requested, reason)
    end
end

-- Begin posting `numStacks` auctions of `stackSize` at the given per-unit
-- prices. Non-destructive: each stack is split off a bag stack, so partials
-- and other items are never shuffled. Returns (true) or (false, reason).
function sell.StartPosting(itemId, itemName, stackSize, numStacks,
                           unitBuyout, unitStart, minutes, callbacks)
    if sell.job then return false, "Already posting." end
    if not itemId then return false, "No item selected." end
    if not stackSize or stackSize < 1 then return false, "Bad stack size." end
    if not numStacks or numStacks < 1 then return false, "Bad stack count." end
    if not minutes or minutes <= 0 then return false, "Pick a duration." end
    if CursorHasItem() then
        return false, "Clear your cursor first."
    end
    if not (unitBuyout and unitBuyout > 0) then
        return false, "Enter a buyout."
    end
    local unitStartUse = unitStart or unitBuyout
    if unitStartUse > unitBuyout then
        return false, "Start bid can't exceed the buyout."
    end
    -- Don't exceed the account cap.
    local room = sell.CAP - sell.OwnerCount()
    if room <= 0 then return false, "You are at the auction cap." end
    if numStacks > room then numStacks = room end
    -- Don't promise more than we can assemble.
    local avail = sell.MaxStacks(itemId, stackSize)
    if avail < 1 then return false, "Not enough of that item to make a stack." end
    if numStacks > avail then numStacks = avail end

    sell.ClearSlot()
    sell.job = {
        itemId = itemId, itemName = itemName, stackSize = stackSize,
        requested = numStacks, remaining = numStacks, posted = 0,
        unitBuyout = unitBuyout, unitStart = unitStartUse, minutes = minutes,
        phase = "assemble", cool = 0, retries = 0, callbacks = callbacks,
    }
    PostDriver():Show()
    return true
end

function sell.PostTick(dt)
    local job = sell.job
    if not job then return end
    job.cool = job.cool - (dt or 0)
    if job.cool > 0 then return end

    if job.remaining <= 0 then
        FinishJob("done")
        return
    end
    if sell.AtCap() then
        FinishJob("cap")
        return
    end

    -- ASSEMBLY STRATEGY. The auction slot reliably accepts a WHOLE bag stack --
    -- that is why posting always worked when the bags already held the right
    -- sizes, and why every attempt that needed a genuine split failed, both
    -- before 1.1.5 and after it. Waiting for the split to reach the cursor
    -- (1.1.5) was necessary but not sufficient.
    --
    -- So we never hand the auction slot a floating split. When the bag has more
    -- than we want, we CARVE: split the exact amount off, drop it into an empty
    -- bag slot, wait for the bags to settle, and then post that new stack down
    -- the same whole-stack path that has always worked. Phases:
    --
    --   assemble -> (exact stack exists?) -> place -> verify -> post
    --            -> (need to carve)       -> carve -> settle -> assemble
    if job.phase == "assemble" then
        local it = sell.GetItem()
        if it and it.itemId == job.itemId and it.count == job.stackSize then
            -- Already assembled (e.g. the user had it slotted). Go straight to
            -- the phase that fires the auction. This used to say "post", which
            -- no branch below handles -- the job would sit in a dead state
            -- forever instead of posting.
            job.phase = "verify"
            return
        end
        if CursorHasItem() then ClearCursor() end
        -- An occupied slot makes ClickAuctionSellItemButton SWAP rather than
        -- place, so empty it before we put anything in.
        if it then sell.ClearSlot() end

        -- Preferred: a bag stack that is already exactly the size we want.
        local bag, slot = FindExactStack(job.itemId, job.stackSize)
        if bag then
            sell.Debug("placing exact stack from bag " .. bag .. " slot " .. slot)
            PickupContainerItem(bag, slot)
            job.phase = "place"
            job.wait  = CURSOR_TIMEOUT
            job.cool  = 0
            return
        end

        -- Otherwise carve one off a larger stack.
        local src, srcSlot = FindStack(job.itemId, job.stackSize + 1)
        if not src then
            -- Nothing big enough either. Items can be briefly absent -- a stack
            -- we just posted leaves the bags via the server -- so retry a few
            -- times before declaring we've run out.
            job.finds = (job.finds or 0) + 1
            if job.finds > MAX_RETRIES then
                sell.Debug("no stack of " .. job.stackSize .. " left; finishing")
                FinishJob("out")
                return
            end
            job.cool = ASSEMBLE_DELAY
            return
        end
        job.finds = 0
        local eb, es = FindEmptySlot()
        if not eb then
            sell.Debug("no free bag slot to carve into")
            FinishJob("nospace")
            return
        end
        -- Never split out of a slot the server is still moving: the call is
        -- silently dropped and we'd waste a retry waiting for a cursor that
        -- was never going to fill.
        if SlotLocked(src, srcSlot) or SlotLocked(eb, es) then
            job.cool = ASSEMBLE_DELAY
            return
        end
        sell.Debug("carving " .. job.stackSize .. " off bag " .. src
            .. " slot " .. srcSlot .. " into bag " .. eb .. " slot " .. es)
        job.carveBag, job.carveSlot = eb, es
        SplitContainerItem(src, srcSlot, job.stackSize)
        job.phase = "carve"
        job.wait  = CURSOR_TIMEOUT
        job.cool  = 0

    elseif job.phase == "carve" then
        -- SplitContainerItem is a server round-trip; wait for the cursor, then
        -- drop the carved stack into the empty slot we reserved.
        if CursorHasItem() then
            PickupContainerItem(job.carveBag, job.carveSlot)
            job.phase = "settle"
            job.wait  = CURSOR_TIMEOUT
            job.cool  = 0
            return
        end
        job.wait = job.wait - (dt or 0)
        if job.wait <= 0 then
            sell.Debug("split never reached the cursor")
            job.retries = job.retries + 1
            if job.retries > MAX_RETRIES then FinishJob("stuck"); return end
            job.phase = "assemble"
            job.cool  = ASSEMBLE_DELAY
        end

    elseif job.phase == "settle" then
        -- Wait for the bags to actually show the new stack, then let assemble
        -- pick it up down the proven whole-stack path.
        if FindExactStack(job.itemId, job.stackSize) then
            if CursorHasItem() then ClearCursor() end
            job.phase = "assemble"
            job.cool  = 0
            return
        end
        job.wait = job.wait - (dt or 0)
        if job.wait <= 0 then
            sell.Debug("carved stack never appeared in the bags")
            job.retries = job.retries + 1
            if job.retries > MAX_RETRIES then FinishJob("stuck"); return end
            job.phase = "assemble"
            job.cool  = ASSEMBLE_DELAY
        end

    elseif job.phase == "place" then
        -- Wait for the pickup to land on the cursor, then hand it to the slot.
        if CursorHasItem() then
            ClickAuctionSellItemButton()               -- cursor -> sell slot
            job.phase = "verify"
            job.cool  = ASSEMBLE_DELAY
            return
        end
        job.wait = job.wait - (dt or 0)
        if job.wait <= 0 then
            sell.Debug("pickup never reached the cursor")
            job.retries = job.retries + 1
            if job.retries > MAX_RETRIES then FinishJob("stuck"); return end
            job.phase = "assemble"
            job.cool  = ASSEMBLE_DELAY
        end

    elseif job.phase == "verify" then
        local it = sell.GetItem()
        if it and it.itemId == job.itemId and it.count == job.stackSize then
            local buyout = math.floor(job.unitBuyout * job.stackSize)
            local start  = math.floor(job.unitStart * job.stackSize)
            if start < 1 then start = 1 end
            StartAuction(start, buyout, job.minutes)   -- posts, clears slot
            job.posted = job.posted + 1
            job.remaining = job.remaining - 1
            job.retries = 0
            job.phase = "assemble"
            job.cool = POST_DELAY
            if job.callbacks and job.callbacks.onProgress then
                job.callbacks.onProgress(job.posted, job.requested)
            end
        else
            -- Assembly didn't land yet; retry a few times, then give up. The
            -- trace names what the slot actually held, which is the one thing
            -- "couldn't assemble a stack" never told anybody.
            local got = "empty"
            if it then
                got = tostring(it.itemId) .. " x" .. tostring(it.count)
            end
            sell.Debug("verify: slot has " .. got .. ", wanted "
                .. tostring(job.itemId) .. " x" .. tostring(job.stackSize))
            job.retries = job.retries + 1
            if job.retries > MAX_RETRIES then
                FinishJob("stuck")
                return
            end
            job.phase = "assemble"
            job.cool = ASSEMBLE_DELAY
        end
    end
end

function sell.PostingActive()
    return sell.job ~= nil
end

function sell.CancelPosting()
    if sell.job then FinishJob("cancelled") end
end
