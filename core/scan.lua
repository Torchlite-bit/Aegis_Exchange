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
--
-- The REAL throttle is the client's own CanSendAuctionQuery() gate: vanilla
-- keeps it shut for ~5s after each query. This wall-clock delay is a floor we
-- add on top of it.
--
-- AuctionQueryThrottle (https://github.com/brues-code/AuctionQueryThrottle) is
-- a DLL -- not an addon, so there is nothing to IsAddOnLoaded() -- that clears
-- that timer as soon as the server's reply lands. With it installed the gate
-- opens almost immediately, so a 4s floor would throw the benefit away.
--
-- So in "auto" (the default) we drop the floor to FAST_DELAY and let the
-- CLIENT'S GATE do the throttling. That is correct either way:
--   * DLL present  -> gate opens at round-trip speed -> we scan fast.
--   * DLL absent   -> gate stays shut ~5s -> we wait exactly as before.
-- No detection needed; the gate IS the detector. "safe" restores the old
-- fixed floor for anyone whose client reports the gate unreliably.
scan.PAGE_DELAY = 4      -- "safe" floor
-- "auto" floor. Deliberately tiny: the CLIENT'S GATE is the real throttle, so
-- this only stops us re-testing it every single frame. It is per PAGE, so keep
-- it small -- at 0.25s a 60-page scan spent 15s doing nothing but waiting on us.
scan.FAST_DELAY = 0.05

-- Gate openings at or under this many seconds mean the throttle has been
-- lifted (the DLL is doing its job). Purely informational -- it drives the
-- readout, not the pacing.
scan.FAST_GATE = 1.5

-- The floor to use right now, per the Aegis-tab setting.
function scan.PageDelay()
    local mode = A.db and A.db.Setting and A.db.Setting("queryThrottle") or "auto"
    if mode == "safe" then return scan.PAGE_DELAY end
    return scan.FAST_DELAY
end

-- True once we've seen the client's gate open fast enough that the vanilla
-- throttle is clearly not in play. Reported in the UI so it's obvious whether
-- AuctionQueryThrottle is actually working.
function scan.FastThrottleSeen()
    return scan.state.fastGate and true or false
end

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
    gateWait      = 0,     -- seconds the CURRENT gate wait has taken
    lastGate      = nil,   -- how long the last gate took to open
    sentAt        = nil,   -- st.elapsed when the current query went out
    lastReply     = nil,   -- how long the SERVER took to answer the last page
    fastGate      = false, -- gate has opened fast enough to mean "throttle lifted"
    tally         = nil,   -- per-run stats for the completion report (see NewTally)
    callbacks     = nil,   -- { onPage = fn(page1, totalPages),
                           --   onComplete = fn(stats) }
}

-- 1.12 quality indices, for the scan report.
scan.QUALITY_NAMES = { [0] = "Poor", [1] = "Common", [2] = "Uncommon",
                       [3] = "Rare", [4] = "Epic", [5] = "Legendary",
                       [6] = "Artifact" }

-- Fresh per-run tally. `seen` maps itemId -> quality so each distinct item is
-- counted once; added/updated split on whether the price DB already knew it.
local function NewTally()
    return { seen = {}, distinct = 0, added = 0, updated = 0, ignored = 0 }
end

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
-- Per-unit buyout = buyoutPrice / count; bid-only auctions (buyout 0) are not
-- fed to the price DB. `owner` may be nil until it resolves; we never wait.
--
-- If the current run supplied an `onListing` callback (the Sell tab uses this
-- to collect every listing of one item), it is invoked for EACH auction on the
-- page as onListing(itemId, name, count, buyout, minBid, owner) — including
-- bid-only ones, so the listings table can show them too.
local function RecordVisiblePage(numOnPage)
    local st = scan.state
    local onListing = st.callbacks and st.callbacks.onListing
    local tally = st.tally
    for i = 1, numOnPage do
        local name, _, count, quality, _, _, minBid, _, buyoutPrice, _, _, owner =
            GetAuctionItemInfo("list", i)
        if name and count and count > 0 then
            local itemId = util.ItemIdFromLink(GetAuctionItemLink("list", i))
            -- Tally BEFORE recording, so "added" means new to the price DB.
            if tally then
                if itemId then
                    if not tally.seen[itemId] then
                        -- Via db.Items(), not db.account.items: price data is
                        -- keyed by realm, so "already known" must mean known
                        -- HERE. Reaching past the accessor would count another
                        -- realm's items as updates on this one.
                        local items = A.db.Items and A.db.Items() or nil
                        local known = items and items[itemId] or nil
                        tally.seen[itemId] = quality or 1
                        tally.distinct = tally.distinct + 1
                        if known then
                            tally.updated = tally.updated + 1
                        else
                            tally.added = tally.added + 1
                        end
                    end
                else
                    -- No resolvable item link: nothing we can price.
                    tally.ignored = tally.ignored + 1
                end
            end
            if buyoutPrice and buyoutPrice > 0 and itemId then
                A.db.RecordAuction(
                    itemId, math.floor(buyoutPrice / count), name)
            end
            if onListing then
                onListing(itemId, name, count, buyoutPrice or 0,
                          minBid or 0, owner)
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
    st.sentAt = st.elapsed   -- to measure the server's round trip
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
            -- Past our floor: the client's own gate now decides. This is the
            -- part that adapts -- with AuctionQueryThrottle it opens at
            -- round-trip speed, without it we sit here the vanilla ~5s.
            st.gateWait = st.gateWait + dt
            if CanSendAuctionQuery() then
                st.lastGate = st.gateWait
                if st.gateWait <= scan.FAST_GATE then
                    if not st.fastGate then
                        scan.Debug(string.format(
                            "query gate opened in %.2fs \226\128\148 throttle"
                            .. " looks lifted (AuctionQueryThrottle?)",
                            st.gateWait))
                    end
                    st.fastGate = true
                end
                st.gateWait = 0
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
    -- Roll the per-run tally into the report: distinct items, a per-quality
    -- breakdown, and how many items were new to the price DB vs. refreshed.
    local t = st.tally
    if t then
        local byQuality = {}
        for _, q in pairs(t.seen) do
            byQuality[q] = (byQuality[q] or 0) + 1
        end
        stats.items     = t.distinct
        stats.byQuality = byQuality
        stats.added     = t.added
        stats.updated   = t.updated
        stats.ignored   = t.ignored
    end
    -- Item scans (Sell tab price lookups) pass stampLast=false so they feed
    -- the price DB WITHOUT resetting the Scan tab's "last full scan" marker.
    if not (st.callbacks and st.callbacks.stampLast == false) then
        A.db.SetLastScan(st.pagesDoneTotal, st.scanned, IsFullRun(st))
    end
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
        st.cooldown = scan.PageDelay()
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
    -- How long the SERVER took to answer. Together with the gate wait this
    -- accounts for the whole per-page cost, so a slow scan can be blamed
    -- correctly: our floor, the client's throttle, or the server itself.
    if st.sentAt then
        st.lastReply = st.elapsed - st.sentAt
        st.sentAt = nil
    end
    scan.Debug(string.format(
        "page %d / %d received in %.2fs \226\128\148 %d on page, %d total",
        st.page + 1, st.totalPages, st.lastReply or 0, numOnPage, totalAuctions))
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
        st.cooldown = scan.PageDelay()
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
--   { onPage     = fn(page1based, totalPages),
--     onComplete = fn(stats),
--     onListing  = fn(itemId, name, count, buyout, minBid, owner) }  -- per row
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
    st.tally          = NewTally()
    st.gateWait       = 0
    st.lastGate       = nil
    st.lastReply      = nil
    st.sentAt         = nil
    st.fastGate       = false
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
    st.cooldown = scan.PageDelay()   -- be polite on re-entry
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
    local secPerPage = scan.PageDelay() + 1
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
        lastGate    = st.lastGate,
        lastReply   = st.lastReply,
        fastGate    = st.fastGate and true or false,
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
