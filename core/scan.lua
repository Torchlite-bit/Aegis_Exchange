-- Aegis: Exchange
-- core/scan.lua
--
-- Page-by-page auction scanner for the 1.12 client. Coroutine-free: a hidden
-- OnUpdate driver frame accumulates elapsed time (the global arg1) and only
-- sends the next QueryAuctionItems when the inter-page throttle has passed
-- AND CanSendAuctionQuery() says the client is ready.
--
-- 1.12 rules honored here (see CLAUDE.md):
--   * QueryAuctionItems(name, minLevel, maxLevel, invTypeIndex, classIndex,
--         subclassIndex, page, isUsable, qualityIndex) — 9 args, page is
--         0-indexed, no getAll.
--   * Poll CanSendAuctionQuery() before EVERY query; ~4s between pages.
--   * Wait for AUCTION_ITEM_LIST_UPDATE before reading a page. Page size 50.
--   * GetAuctionItemInfo("list", i) returns exactly 12 values; `owner` may be
--     nil until it resolves — we never wait for owners while price scanning.

local A = AegisExchange
A.scan = {}
local scan = A.scan
local util = A.util

-- Auctions returned per page by the 1.12 server.
scan.PAGE_SIZE = 50

-- Seconds to wait between page queries (on top of CanSendAuctionQuery).
scan.PAGE_DELAY = 4

-- Seconds to wait for AUCTION_ITEM_LIST_UPDATE before re-sending the same
-- page (lost replies happen on laggy servers).
scan.REPLY_TIMEOUT = 15

-- Scanner state machine. phase is one of:
--   "idle"          not scanning
--   "wait_query"    counting down cooldown, then polling CanSendAuctionQuery
--   "wait_results"  query sent, waiting for AUCTION_ITEM_LIST_UPDATE
--   "paused"        user pause / AH closed; Continue() picks the scan back up
scan.state = {
    phase         = "idle",
    query         = nil,   -- normalized query table
    page          = 0,     -- next page to request (0-indexed)
    lastCompleted = -1,    -- last fully processed page
    totalPages    = 0,     -- known after the first page arrives
    totalAuctions = 0,
    scanned       = 0,     -- auctions recorded this scan
    elapsed       = 0,     -- seconds actually spent scanning (pauses excluded)
    cooldown      = 0,     -- seconds left before the next query may be sent
    timeout       = 0,     -- seconds left waiting for the current reply
    callbacks     = nil,   -- { onPage = fn(page1, totalPages),
                           --   onComplete = fn(stats) }
}

-- ---------------------------------------------------------------------------
-- Recording
-- ---------------------------------------------------------------------------

-- Read every auction on the currently visible "list" page into the price DB.
-- Runs on EVERY AUCTION_ITEM_LIST_UPDATE — manual browsing feeds the DB too.
-- Per-unit buyout = buyoutPrice / count; bid-only auctions (buyout 0) are
-- ignored, and so is `owner` (it may be nil until resolved; we never wait).
local function RecordVisiblePage(numOnPage)
    for i = 1, numOnPage do
        local name, _, count, _, _, _, _, _, buyoutPrice =
            GetAuctionItemInfo("list", i)
        if name and count and count > 0
            and buyoutPrice and buyoutPrice > 0 then
            local itemId = util.ItemIdFromLink(GetAuctionItemLink("list", i))
            if itemId then
                A.db.RecordAuction(
                    itemId, math.floor(buyoutPrice / count), name)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Query sending
-- ---------------------------------------------------------------------------

local function SendQuery()
    local st = scan.state
    local q = st.query
    -- The 9-arg 1.12 signature; any nil means "no filter".
    QueryAuctionItems(q.name, q.minLevel, q.maxLevel, q.invType,
                      q.class, q.subclass, st.page, nil, q.quality)
    st.phase = "wait_results"
    st.timeout = scan.REPLY_TIMEOUT
end

-- ---------------------------------------------------------------------------
-- OnUpdate driver
-- ---------------------------------------------------------------------------

-- Hidden while idle/paused so OnUpdate only runs mid-scan.
scan.driver = CreateFrame("Frame", "AegisExchangeScanDriver")
scan.driver:Hide()

function scan.OnUpdate(dt)
    local st = scan.state
    st.elapsed = st.elapsed + dt
    if st.phase == "wait_query" then
        st.cooldown = st.cooldown - dt
        if st.cooldown <= 0 and CanSendAuctionQuery() then
            SendQuery()
        end
    elseif st.phase == "wait_results" then
        st.timeout = st.timeout - dt
        if st.timeout <= 0 then
            -- Reply lost; fall back and re-send the same page.
            st.phase = "wait_query"
            st.cooldown = 1
        end
    end
end

-- OnUpdate receives no args on this client; elapsed is the GLOBAL arg1.
scan.driver:SetScript("OnUpdate", function()
    scan.OnUpdate(arg1)
end)

-- ---------------------------------------------------------------------------
-- Page arrival
-- ---------------------------------------------------------------------------

local function Finish()
    local st = scan.state
    local stats = {
        pages    = st.totalPages,
        auctions = st.scanned,
        duration = st.elapsed,
    }
    A.db.SetLastScan(st.totalPages, st.scanned)
    st.phase = "idle"
    scan.driver:Hide()
    if st.callbacks and st.callbacks.onComplete then
        st.callbacks.onComplete(stats)
    end
end

function scan.OnListUpdate()
    local numOnPage, totalAuctions = GetNumAuctionItems("list")

    -- Passive feed: every result page anyone looks at updates the DB.
    RecordVisiblePage(numOnPage)

    local st = scan.state
    if st.phase ~= "wait_results" then return end

    -- This is the page we asked for: accept it and advance.
    st.totalAuctions = totalAuctions
    st.totalPages = math.ceil(totalAuctions / scan.PAGE_SIZE)
    if st.totalPages < 1 then st.totalPages = 1 end
    st.scanned = st.scanned + numOnPage
    st.lastCompleted = st.page
    if st.callbacks and st.callbacks.onPage then
        st.callbacks.onPage(st.page + 1, st.totalPages)
    end
    if st.page + 1 >= st.totalPages then
        Finish()
    else
        st.page = st.page + 1
        st.phase = "wait_query"
        st.cooldown = scan.PAGE_DELAY
    end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Begin a scan. `query` = { name, minLevel, maxLevel, invType, class,
-- subclass, quality } — any nil field means no filter, {} is a full scan.
-- `callbacks` (optional) = { onPage = fn(page1based, totalPages),
-- onComplete = fn(stats) }.
function scan.Start(query, callbacks)
    local st = scan.state
    st.query         = query or {}
    st.callbacks     = callbacks
    st.page          = 0
    st.lastCompleted = -1
    st.totalPages    = 0
    st.totalAuctions = 0
    st.scanned       = 0
    st.elapsed       = 0
    st.cooldown      = 0     -- first query goes as soon as the client allows
    st.timeout       = 0
    st.phase         = "wait_query"
    scan.driver:Show()
end

-- Pause: stop querying but keep all progress. A reply already in flight is
-- ignored (OnListUpdate only advances in wait_results), so Continue() safely
-- re-queries the first page we haven't completed.
function scan.Pause()
    local st = scan.state
    if st.phase == "wait_query" or st.phase == "wait_results" then
        st.phase = "paused"
        scan.driver:Hide()
    end
end

-- Resume from the last completed page (works after a manual pause or an
-- AFK/AH-close interruption within the session).
function scan.Continue()
    local st = scan.state
    if st.phase ~= "paused" then return end
    st.page = st.lastCompleted + 1
    st.cooldown = scan.PAGE_DELAY   -- be polite on re-entry
    st.timeout = 0
    st.phase = "wait_query"
    scan.driver:Show()
end

scan.Resume = scan.Continue

-- Abandon the scan entirely.
function scan.Stop()
    local st = scan.state
    st.phase = "idle"
    st.lastCompleted = -1
    st.page = 0
    scan.driver:Hide()
end

function scan.IsRunning()
    local p = scan.state.phase
    return p == "wait_query" or p == "wait_results"
end

function scan.IsPaused()
    return scan.state.phase == "paused"
end

-- Progress snapshot for the UI: current page (1-based, the one in flight or
-- next up), total pages, auctions/sec, and an ETA in seconds derived from the
-- measured per-page pace so it absorbs real-world lag.
function scan.GetProgress()
    local st = scan.state
    local pagesDone = st.lastCompleted + 1
    local rate = 0
    if st.elapsed > 0 then
        rate = st.scanned / st.elapsed
    end
    local secPerPage = scan.PAGE_DELAY + 1
    if pagesDone > 0 then
        secPerPage = st.elapsed / pagesDone
    end
    local remaining = st.totalPages - pagesDone
    if remaining < 0 then remaining = 0 end
    return {
        page       = st.page + 1,
        totalPages = st.totalPages,
        pagesDone  = pagesDone,
        scanned    = st.scanned,
        elapsed    = st.elapsed,
        rate       = rate,
        eta        = remaining * secPerPage,
        phase      = st.phase,
    }
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

A.RegisterEvent("AUCTION_ITEM_LIST_UPDATE", function()
    scan.OnListUpdate()
end)

-- Walking away from the auctioneer mid-scan: keep progress, auto-pause.
A.RegisterEvent("AUCTION_HOUSE_CLOSED", function()
    if scan.IsRunning() then
        scan.Pause()
    end
end)
