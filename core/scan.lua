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
-- A scan walks a LIST of category queries back-to-back (a full scan is just a
-- one-element list holding an empty query; a targeted scan holds one query per
-- selected class/subclass). The page/totalPages/lastCompleted fields track the
-- CURRENT category; queryIndex/pagesDoneTotal track the run across categories.
scan.state = {
    phase         = "idle",
    queries       = nil,   -- array of query tables (categories to scan)
    queryIndex    = 1,     -- which category we're on
    query         = nil,   -- normalized query table (queries[queryIndex])
    page          = 0,     -- next page to request in this category (0-indexed)
    lastCompleted = -1,    -- last fully processed page in this category
    totalPages    = 0,     -- pages in this category (known after page 0)
    totalAuctions = 0,
    pagesDoneTotal = 0,    -- pages completed in FINISHED categories
    scanned       = 0,     -- auctions recorded this whole run
    elapsed       = 0,     -- seconds actually spent scanning (pauses excluded)
    cooldown      = 0,     -- seconds left before the next query may be sent
    timeout       = 0,     -- seconds left waiting for the current reply
    sent          = 0,     -- queries actually handed to the client this run
    retries       = 0,     -- re-sends of the CURRENT page (reply never came)
    waitOk        = 0,     -- seconds spent blocked on CanSendAuctionQuery()
    callbacks     = nil,   -- { onPage = fn(page1, totalPages),
                           --   onComplete = fn(stats) }
}

-- Chat trace of every scanner transition; toggled with "/aex debug". This is
-- how we tell WHICH leg a stall is on: query never sent (CanSendAuctionQuery
-- stays false) vs. query sent but no AUCTION_ITEM_LIST_UPDATE ever arrives
-- (dead AH session / server rejected the query).
function scan.Debug(msg)
    if A.debugScan and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff5fc8f8Aegis scan:|r " .. msg)
    end
end

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
    -- The 9-arg 1.12 signature. name/minLevel/maxLevel are sent as STRINGS
    -- ("" when unused) because that is exactly what the stock browse UI sends
    -- (it passes GetText() results) and what Auctionator sends — some servers
    -- ignore a query with nils in those slots. The index args stay nil for
    -- "no filter".
    QueryAuctionItems(q.name or "", q.minLevel or "", q.maxLevel or "",
                      q.invType, q.class, q.subclass, st.page, nil, q.quality)
    st.sent = st.sent + 1
    st.phase = "wait_results"
    st.timeout = scan.REPLY_TIMEOUT
    scan.Debug(string.format(
        "query sent \226\128\148 cat %d, page %d (attempt %d)",
        st.queryIndex, st.page, st.retries + 1))
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
        if st.cooldown <= 0 then
            if CanSendAuctionQuery() then
                st.waitOk = 0
                SendQuery()
            else
                -- Client says "not yet". If this never clears, no query is
                -- ever sent — one of the two stall legs. Trace it.
                st.waitOk = st.waitOk + dt
                if st.waitOk >= 5 then
                    st.waitOk = st.waitOk - 5
                    scan.Debug(
                        "still blocked \226\128\148 CanSendAuctionQuery() "
                        .. "has returned false for 5s+")
                end
            end
        end
    elseif st.phase == "wait_results" then
        st.timeout = st.timeout - dt
        if st.timeout <= 0 then
            -- Reply lost; fall back and re-send the same page. Climbing
            -- retries = queries go out but the server never answers (the
            -- other stall leg: dead session / rejected query).
            st.retries = st.retries + 1
            scan.Debug(string.format(
                "no reply for page %d after %ds \226\128\148 retry %d",
                st.page, scan.REPLY_TIMEOUT, st.retries))
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

-- Was the whole run a full (unfiltered) scan? True only for a single query
-- with no class filter — used so the DB can distinguish full vs targeted.
local function IsFullRun(st)
    return table.getn(st.queries) == 1 and st.queries[1]
        and st.queries[1].class == nil and st.queries[1].name == nil
end

local function Finish()
    local st = scan.state
    local stats = {
        pages      = st.pagesDoneTotal,
        auctions   = st.scanned,
        duration   = st.elapsed,
        categories = table.getn(st.queries),
    }
    A.db.SetLastScan(st.pagesDoneTotal, st.scanned, IsFullRun(st))
    st.phase = "idle"
    scan.driver:Hide()
    if st.callbacks and st.callbacks.onComplete then
        st.callbacks.onComplete(stats)
    end
end

-- Begin the current category (queries[queryIndex]) at page 0.
local function StartCurrentQuery()
    local st = scan.state
    st.query = st.queries[st.queryIndex]
    st.page = 0
    st.lastCompleted = -1
    st.totalPages = 0
    st.retries = 0
    st.phase = "wait_query"
    -- First category goes immediately; later categories wait a polite gap.
    if st.queryIndex == 1 then
        st.cooldown = 0
    else
        st.cooldown = scan.PAGE_DELAY
    end
    st.timeout = 0
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
    st.retries = 0
    scan.Debug(string.format(
        "page %d / %d received \226\128\148 %d on page, %d total",
        st.page + 1, st.totalPages, numOnPage, totalAuctions))
    if st.callbacks and st.callbacks.onPage then
        st.callbacks.onPage(st.page + 1, st.totalPages)
    end
    if st.page + 1 >= st.totalPages then
        -- Current category finished; move to the next, or finish the run.
        st.pagesDoneTotal = st.pagesDoneTotal + st.totalPages
        if st.queryIndex < table.getn(st.queries) then
            st.queryIndex = st.queryIndex + 1
            StartCurrentQuery()
        else
            Finish()
        end
    else
        st.page = st.page + 1
        st.phase = "wait_query"
        st.cooldown = scan.PAGE_DELAY
    end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Begin a scan. Accepts EITHER a single query table OR a list of them:
--   scan.Start({})                         -- full scan (whole AH)
--   scan.Start({ class = 5, subclass = 1 }) -- one category
--   scan.Start({ {class=5,subclass=1}, {class=2} }) -- several categories
-- A query = { name, minLevel, maxLevel, invType, class, subclass, quality };
-- any nil field means "no filter". `callbacks` (optional) =
-- { onPage = fn(page1based, totalPages), onComplete = fn(stats) }.
function scan.Start(queryOrList, callbacks)
    local st = scan.state
    local queries
    if type(queryOrList) == "table" and type(queryOrList[1]) == "table" then
        queries = queryOrList       -- already a list of queries
    else
        queries = { queryOrList or {} }
    end
    st.queries        = queries
    st.queryIndex     = 1
    st.callbacks      = callbacks
    st.pagesDoneTotal = 0
    st.totalAuctions  = 0
    st.scanned        = 0
    st.elapsed        = 0
    st.sent           = 0
    st.retries        = 0
    st.waitOk         = 0
    StartCurrentQuery()
    st.cooldown       = 0    -- first query goes as soon as the client allows
    scan.driver:Show()
    scan.Debug("scan started \226\128\148 "
        .. table.getn(queries) .. " category query(ies)")
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
    local pagesDone = st.lastCompleted + 1            -- within this category
    local overallDone = (st.pagesDoneTotal or 0) + pagesDone
    local rate = 0
    if st.elapsed > 0 then
        rate = st.scanned / st.elapsed
    end
    local secPerPage = scan.PAGE_DELAY + 1
    if overallDone > 0 then
        secPerPage = st.elapsed / overallDone
    end
    -- ETA covers the remaining pages of the CURRENT category; future
    -- categories' page counts are unknown until we query them.
    local remaining = st.totalPages - pagesDone
    if remaining < 0 then remaining = 0 end
    return {
        page        = st.page + 1,
        totalPages  = st.totalPages,
        pagesDone   = pagesDone,
        overallDone = overallDone,
        catIndex    = st.queryIndex or 1,
        catCount    = st.queries and table.getn(st.queries) or 1,
        scanned     = st.scanned,
        elapsed     = st.elapsed,
        rate        = rate,
        eta         = remaining * secPerPage,
        sent        = st.sent or 0,
        retries     = st.retries or 0,
        phase       = st.phase,
    }
end

-- The auction house category tree, from the 1.12 API (only valid while the AH
-- is open). Returns a list of
--   { name, class = classIndex, subs = { { name, class, subclass }, ... } }
-- suitable for a class -> subclass picker.
function scan.GetCategories()
    local classNames = { GetAuctionItemClasses() }
    local out = {}
    local nc = table.getn(classNames)
    local ci = 1
    while ci <= nc do
        local cat = { name = classNames[ci], class = ci, subs = {} }
        local subNames = { GetAuctionItemSubClasses(ci) }
        local ns = table.getn(subNames)
        local si = 1
        while si <= ns do
            table.insert(cat.subs,
                { name = subNames[si], class = ci, subclass = si })
            si = si + 1
        end
        table.insert(out, cat)
        ci = ci + 1
    end
    return out
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
