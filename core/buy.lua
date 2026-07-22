-- Aegis: Exchange
-- core/buy.lua
--
-- Shopping engine: search the AH by name, page through the results, and
-- buy/bid. Unlike the scanner (which walks every page to feed the price DB),
-- the Buy tab browses ONE page at a time and keeps each listing's real "list"
-- index, because on 1.12 you can only bid/buyout an auction that is on the
-- currently loaded page.
--
-- 1.12 API used here (verified against the Turtle UI source):
--   QueryAuctionItems(name, minLevel, maxLevel, invType, class, subclass,
--                     page, isUsable, quality)         -- 9 args, page 0-indexed
--   GetNumAuctionItems("list")            -> numOnPage, totalAuctions
--   GetAuctionItemInfo("list", i)         -> 12 values (see CLAUDE.md)
--   PlaceAuctionBid("list", index, amount)  -- amount >= buyout => buyout,
--                                              otherwise a bid
--   CanSendAuctionQuery()                   -- gate before every query

local A = AegisExchange
A.buy = {}
local buy = A.buy
local util = A.util

buy.PAGE_SIZE   = 50
buy.QUERY_DELAY = 0.5    -- polite gap before (re)querying a page
buy.TIMEOUT     = 8      -- seconds to wait for a page reply before retrying

buy.state = {
    phase      = "idle",   -- idle | wait_query | wait_results
    name       = "",
    page       = 0,        -- 0-indexed current page
    totalPages = 0,
    total      = 0,
    rows       = {},       -- current page's listings (sorted for display)
    cooldown   = 0,
    timeout    = 0,
    callbacks  = nil,      -- { onResults = fn(rows), onState = fn(phase) }
}

buy.driver = CreateFrame("Frame", "AegisExchangeBuyDriver")
buy.driver:Hide()

-- Another AH consumer (scan / posting) is using the query channel.
function buy.IsBusy()
    return A.scan.IsRunning() or A.scan.IsPaused() or A.sell.PostingActive()
end

local function Notify()
    local st = buy.state
    if st.callbacks and st.callbacks.onState then
        st.callbacks.onState(st.phase)
    end
end

-- Kick off a fresh search for `name` at page 0.
function buy.Search(name, callbacks)
    if buy.IsBusy() then
        return false, "The AH is busy (scan or posting in progress)."
    end
    local st = buy.state
    st.name      = name or ""
    st.page      = 0
    st.callbacks = callbacks or st.callbacks
    st.phase     = "wait_query"
    st.cooldown  = 0
    st.timeout   = 0
    buy.driver:Show()
    Notify()
    return true
end

-- Re-query the current page (after a purchase, or to refresh).
function buy.Refresh()
    local st = buy.state
    if st.phase ~= "idle" then return end
    st.phase    = "wait_query"
    st.cooldown = buy.QUERY_DELAY
    buy.driver:Show()
    Notify()
end

function buy.GotoPage(page)
    if buy.IsBusy() then return end
    local st = buy.state
    if page < 0 then page = 0 end
    st.page     = page
    st.phase    = "wait_query"
    st.cooldown = buy.QUERY_DELAY
    buy.driver:Show()
    Notify()
end

function buy.NextPage()
    if buy.state.page + 1 < buy.state.totalPages then
        buy.GotoPage(buy.state.page + 1)
    end
end

function buy.PrevPage()
    if buy.state.page > 0 then
        buy.GotoPage(buy.state.page - 1)
    end
end

local function SendQuery()
    local st = buy.state
    -- name/minLevel/maxLevel as strings (see CLAUDE.md rule 9).
    QueryAuctionItems(st.name or "", "", "", nil, nil, nil, st.page, nil, nil)
    st.phase   = "wait_results"
    st.timeout = buy.TIMEOUT
    Notify()
end

function buy.OnUpdate(dt)
    local st = buy.state
    if st.phase == "wait_query" then
        st.cooldown = st.cooldown - dt
        if st.cooldown <= 0 and CanSendAuctionQuery() then
            SendQuery()
        end
    elseif st.phase == "wait_results" then
        st.timeout = st.timeout - dt
        if st.timeout <= 0 then
            st.phase    = "wait_query"    -- lost reply; retry the page
            st.cooldown = 1
        end
    end
end
buy.driver:SetScript("OnUpdate", function() buy.OnUpdate(arg1) end)

-- Read the currently visible "list" page into sorted rows. Each row keeps its
-- real `index` so a later bid/buyout targets the right auction.
function buy.ReadPage()
    local st = buy.state
    local numOnPage, total = GetNumAuctionItems("list")
    st.total = total or 0
    st.totalPages = math.ceil(st.total / buy.PAGE_SIZE)
    if st.totalPages < 1 then st.totalPages = 1 end

    local me = UnitName and UnitName("player") or nil
    local rows = {}
    local i = 1
    while i <= numOnPage do
        local name, _, count, quality, canUse, level, minBid, minInc,
              buyout, bidAmount, highBidder, owner = GetAuctionItemInfo("list", i)
        if name then
            count = count or 1
            local nextBid
            if bidAmount and bidAmount > 0 then
                nextBid = bidAmount + (minInc or 0)
            else
                nextBid = minBid or 0
            end
            table.insert(rows, {
                index   = i,
                name    = name,
                count   = count,
                quality = quality,
                canUse  = canUse,
                level   = level,
                buyout  = buyout or 0,
                unit    = (buyout and buyout > 0) and math.floor(buyout / count)
                          or nil,
                minBid  = minBid or 0,
                bidAmount = bidAmount or 0,
                nextBid = nextBid,
                owner   = owner,
                itemId  = util.ItemIdFromLink(GetAuctionItemLink("list", i)),
                mine    = (owner and me and owner == me) and true or false,
            })
        end
        i = i + 1
    end

    -- Cheapest unit buyout first (bid-only auctions, unit = nil, sink to the
    -- bottom); the real `index` is preserved so buying still hits the right
    -- listing.
    table.sort(rows, function(a, b)
        if not a.unit and not b.unit then return false end
        if not a.unit then return false end   -- a is bid-only -> after b
        if not b.unit then return true end    -- b is bid-only -> a before
        return a.unit < b.unit
    end)

    st.rows  = rows
    st.phase = "idle"
    buy.driver:Hide()
    if st.callbacks and st.callbacks.onResults then
        st.callbacks.onResults(rows)
    end
    Notify()
end

-- The listing at `row.index` still matches what we displayed (guards against
-- the page shifting between read and click).
function buy.Verify(row)
    local name, _, count, _, _, _, _, _, buyout = GetAuctionItemInfo("list", row.index)
    return name == row.name and count == row.count
        and (buyout or 0) == row.buyout
end

-- Buy out `row`. Returns (true) or (false, reason). The refreshed page arrives
-- via the AUCTION_ITEM_LIST_UPDATE the purchase triggers.
function buy.Buyout(row)
    if not row then return false, "No auction selected." end
    if row.mine then return false, "That's your own auction." end
    if not row.buyout or row.buyout <= 0 then return false, "No buyout price." end
    if not buy.Verify(row) then
        return false, "Listing changed \226\128\148 search again."
    end
    -- Arm the re-read BEFORE bidding: the purchase's AUCTION_ITEM_LIST_UPDATE
    -- can arrive immediately, and we want our handler to pick it up.
    local st = buy.state
    st.phase   = "wait_results"
    st.timeout = buy.TIMEOUT
    buy.driver:Show()
    PlaceAuctionBid("list", row.index, row.buyout)
    return true
end

-- Place a bid of `amount` (defaults to the minimum next bid) on `row`.
function buy.Bid(row, amount)
    if not row then return false, "No auction selected." end
    if row.mine then return false, "That's your own auction." end
    amount = amount or row.nextBid
    if not amount or amount < row.nextBid then
        return false, "Bid is below the minimum."
    end
    if row.buyout > 0 and amount >= row.buyout then
        return buy.Buyout(row)      -- a bid at/above buyout IS a buyout
    end
    if not buy.Verify(row) then
        return false, "Listing changed \226\128\148 search again."
    end
    local st = buy.state
    st.phase   = "wait_results"
    st.timeout = buy.TIMEOUT
    buy.driver:Show()
    PlaceAuctionBid("list", row.index, amount)
    return true
end

function buy.GetResults()
    return buy.state.rows, buy.state.page, buy.state.totalPages, buy.state.total
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

-- Read a page only when WE asked for it; otherwise stay out of the way (the
-- scanner's own handler still feeds the price DB from this same event).
A.RegisterEvent("AUCTION_ITEM_LIST_UPDATE", function()
    if buy.state.phase == "wait_results" then
        buy.ReadPage()
    end
end)

-- Walking away from the auctioneer ends any in-flight browse.
A.RegisterEvent("AUCTION_HOUSE_CLOSED", function()
    buy.state.phase = "idle"
    buy.driver:Hide()
end)
