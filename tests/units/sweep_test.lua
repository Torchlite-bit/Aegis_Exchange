-- Aegis: Exchange -- tests/units/sweep_test.lua
--
-- Skipping pages that a post-filter emptied.
--
-- THE BUG THIS SUITE PINS. Aegis's own filters -- /vendor-profit, /tooltip,
-- exact, stack size, a price cap -- run on the CLIENT, over the 50 rows the
-- client is holding. 1.12 has no working getAll, so a page is the largest
-- thing anyone can ask for, and the SERVER decides which 50 rows that is.
--
-- A player searched `vendor-profit/1c` over 277 pages and got two blank pages
-- before page 3 finally showed fifteen matches. Nothing was broken: the
-- matches were on page 3 because that is where the server had put them, and
-- page 0 is merely the first 50 rows, not the best. But two blank pages and a
-- pager is indistinguishable from a search that does not work.
--
-- So the engine keeps paging by itself. What has to stay true, and is what
-- every check below is for:
--   * it stops the instant a page HAS matches (never carry someone past it),
--   * it is bounded, so a filter matching nothing cannot walk 277 pages,
--   * it never moves during a batch buyout, which owns the pager,
--   * and every page still goes out through the CanSendAuctionQuery() gate.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)
local buy = A.buy

W.player = "Tester"

local SRC = "ui/frame.lua"
local function Source()
    local f = assert(io.open(SRC, "r"), "run this from the repo root")
    local src = f:read("*a")
    f:close()
    return src
end

local function extract(signature)
    local body, grabbing = {}, false
    for line in string.gfind(Source(), "([^\n]*)\n") do
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
    "function ui.SweepStatus(",
    "function ui.SkippedNote(",
}) do
    local fn, err = loadstring(extract(sig), sig)
    if not fn then error(sig .. " will not compile: " .. tostring(err)) end
    fn()
end

-- A full argument set for buy.SweepDecision, so each test below states only
-- the one thing it is about.
local function plan(over)
    local s = {
        matched = 0, rawTotal = 500, page = 0, totalPages = 10,
        termIndex = 1, totalTerms = 1, steps = 0, limit = 25,
        enabled = true, batch = false,
    }
    for k, v in pairs(over or {}) do s[k] = v end
    return buy.SweepDecision(s)
end

-- ---------------------------------------------------------------------------
H.section("when the sweep moves")
-- ---------------------------------------------------------------------------

H.eq("an emptied page with more to come advances", plan{}, "advance")

-- The point of the whole feature: a page the SERVER matched (rawTotal 500)
-- but OUR filter emptied is not an answer, it is an unfinished look.
H.eq("a filter emptying every row is not an answer",
     plan{ matched = 0, rawTotal = 500 }, "advance")

-- Crossing an OR-term boundary counts as "more to look at", exactly as
-- buy.Advance treats it -- a semicolon query browses as one search.
H.eq("the last page of term 1 of 3 still has somewhere to go",
     plan{ page = 9, totalPages = 10, termIndex = 1, totalTerms = 3 },
     "advance")

-- ---------------------------------------------------------------------------
H.section("when the sweep stops")
-- ---------------------------------------------------------------------------

-- THE SAFETY PROPERTY. One match is enough to stop. A sweep that paged past
-- results would be worse than the blank page it replaced.
H.eq("one match stops it", plan{ matched = 1 }, "matched")
H.eq("many matches stop it", plan{ matched = 50 }, "matched")

-- Nothing the server matched means there is no next page to ask for. Advancing
-- here would query a page that does not exist and blame a filter that never
-- ran -- "No auctions found." is the true answer.
H.eq("a search the server matched nothing for stops",
     plan{ rawTotal = 0 }, "empty")
-- Spelled out rather than via plan{}, because `rawTotal = nil` in a table
-- constructor is not an override -- it is an absent key, and the helper would
-- quietly hand back the default 500.
H.eq("...and a total the client never gave us is read the same way",
     buy.SweepDecision{ matched = 0, page = 0, totalPages = 10,
                        termIndex = 1, totalTerms = 1, steps = 0, limit = 25,
                        enabled = true, batch = false }, "empty")

H.eq("the last page of the last term stops",
     plan{ page = 9, totalPages = 10, termIndex = 1, totalTerms = 1 }, "end")
H.eq("the last page of the LAST term of three stops",
     plan{ page = 9, totalPages = 10, termIndex = 3, totalTerms = 3 }, "end")

-- BOUNDED. This is what keeps `vendor-profit` over 277 pages from running the
-- whole auction house unattended.
H.eq("the budget stops it", plan{ steps = 25, limit = 25 }, "limit")
H.eq("one page short of the budget still moves",
     plan{ steps = 24, limit = 25 }, "advance")

-- "end" is decided BEFORE "limit": when the budget runs out on the last page
-- there is nothing to press the pager for, and saying so would be an
-- instruction that cannot work.
H.eq("out of pages AND out of budget reports the pages",
     plan{ steps = 25, limit = 25, page = 9, totalPages = 10 }, "end")

H.eq("switched off, it never moves", plan{ enabled = false }, "off")
-- A batch buyout re-queries its own page after every purchase. A sweep
-- stepping in there would page the list out from under the batch's next
-- fingerprint lookup.
H.eq("a batch buyout owns the pager", plan{ batch = true }, "off")
H.eq("...even on a page a filter emptied",
     plan{ batch = true, matched = 0, rawTotal = 500 }, "off")

-- ---------------------------------------------------------------------------
H.section("the setting")
-- ---------------------------------------------------------------------------

H.check("on by default", buy.SweepEnabled())
A.db.SetSetting("sweepEmptyPages", false)
H.check("...and off when turned off", not buy.SweepEnabled())
A.db.SetSetting("sweepEmptyPages", true)
H.check("...and back on again", buy.SweepEnabled())

-- ---------------------------------------------------------------------------
H.section("end to end: matches on page 3 of a filtered search")
-- ---------------------------------------------------------------------------

local function auction(name, count, buyout)
    return {
        name = name, count = count or 1, buyout = buyout or 100,
        minBid = buyout or 100, minIncrement = 0, bidAmount = 0,
        owner = "Someone", level = 1, quality = 1, timeLeft = 4,
    }
end

-- Fill a page with rows the exact-name filter will throw away.
local function junkPage(n)
    local rows = {}
    local i = 1
    while i <= n do
        table.insert(rows, auction("Linen Cloth", 20, 1000))
        i = i + 1
    end
    return rows
end

-- Tick the driver until it sends the next query, then answer it with `rows`.
-- The gate is reopened first, the way a client reopens it once the reply
-- lands -- the engine must WAIT on it either way (HARD RULE 10).
local function answer(rows, total)
    W.queryOpen = true
    local before = table.getn(W.queries)
    W.TickUntil(buy.driver,
        function() return table.getn(W.queries) > before end, 50)
    W.SetPage(rows, total)
    buy.ReadPage()
end

do
    W.queries = {}
    W.queryOpen = true
    buy.Search("[Silk Cloth]")

    -- 150 auctions -> 3 pages. Silk Cloth is only on the third.
    answer(junkPage(50), 150)
    H.eq("page 0 matched nothing", table.getn(buy.state.rows), 0)
    local sweeping, steps = buy.SweepState()
    H.check("...so the engine is already moving", sweeping)
    H.eq("...and counts the page it skipped", steps, 1)

    answer(junkPage(50), 150)
    H.eq("page 1 matched nothing either", table.getn(buy.state.rows), 0)
    local sw2, steps2 = buy.SweepState()
    H.check("...still moving", sw2)
    H.eq("...two pages skipped", steps2, 2)

    local hit = junkPage(49)
    table.insert(hit, auction("Silk Cloth", 20, 5000))
    answer(hit, 150)

    H.eq("page 2 is where the server put the match",
         table.getn(buy.state.rows), 1)
    H.eq("...and it is the row we searched for",
         buy.state.rows[1].name, "Silk Cloth")
    local sw3, steps3, stop3 = buy.SweepState()
    H.check("the sweep stopped on it", not sw3)
    H.eq("...because it matched", stop3, "matched")
    H.eq("...having skipped two pages to get here", steps3, 2)

    -- THE PAGES WERE REALLY ASKED FOR, in order, through the gate. Three
    -- queries for three pages: page 0 from the search, 1 and 2 from the sweep.
    H.eq("three queries went out", table.getn(W.queries), 3)
    H.eq("first was page 0", W.queries[1].page, 0)
    H.eq("then page 1", W.queries[2].page, 1)
    H.eq("then page 2", W.queries[3].page, 2)
end

-- ---------------------------------------------------------------------------
H.section("what SweepStep hands the decision")
-- ---------------------------------------------------------------------------

-- The decision is only as good as the arguments it is given, and the two that
-- cannot be read off the page -- is a batch running, is the wire busy -- are
-- exactly the two a wiring mistake would hardcode.

do
    -- A batch buyout re-queries its own page after every purchase. The sweep
    -- must see that and stand down; page 0 of 3 with nothing matched is
    -- otherwise a textbook "advance".
    W.queryOpen = true
    buy.Search("[Silk Cloth]")
    answer(junkPage(50), 150)
    H.eq("no batch: the sweep moves", buy.state.sweepStop, "advance")

    local wasBatch = buy.batch
    buy.batch = { active = true }
    W.queryOpen = true
    buy.ResetSweep()
    H.eq("a batch buyout stands the sweep down", buy.SweepStep(), "off")
    local sweeping, steps = buy.SweepState()
    H.check("...and nothing is in flight", not sweeping)
    H.eq("...and no page was spent", steps, 0)
    buy.batch = wasBatch
end

do
    -- A scan starting mid-sweep takes the query channel. buy.Advance reports
    -- that it did NOT move, and the sweep must believe it -- a sweep that
    -- thinks a page is on its way sits there saying "checking the next one"
    -- about a query that was never sent.
    W.queryOpen = true
    buy.Search("[Silk Cloth]")
    answer(junkPage(50), 150)
    buy.ResetSweep()

    local wasRunning = A.scan.IsRunning
    A.scan.IsRunning = function() return true end
    local stop = buy.SweepStep()
    A.scan.IsRunning = wasRunning

    H.eq("a busy wire is reported as busy", stop, "busy")
    local sweeping = buy.SweepState()
    H.check("...and not as a page in flight", not sweeping)
end

-- ---------------------------------------------------------------------------
H.section("the budget really bounds it")
-- ---------------------------------------------------------------------------

do
    buy.SWEEP_MAX = 3      -- shorter than 25 so the suite is not 26 pages long
    W.queries = {}
    W.queryOpen = true
    buy.Search("[Silk Cloth]")

    -- 50 pages of nothing. The sweep must give up after SWEEP_MAX of them.
    local i = 0
    while i <= buy.SWEEP_MAX do
        answer(junkPage(50), 2500)
        i = i + 1
    end

    local sweeping, steps, stop = buy.SweepState()
    H.check("it gave up", not sweeping)
    H.eq("...at the budget", stop, "limit")
    H.eq("...having skipped exactly the budget", steps, buy.SWEEP_MAX)
    -- One query for the search itself plus one per skipped page. Anything
    -- more means the bound leaked.
    H.eq("and sent no more queries than that",
         table.getn(W.queries), buy.SWEEP_MAX + 1)

    -- The pager starts a FRESH run rather than being permanently spent --
    -- that is what the status line tells the player to press.
    buy.NextPage()
    local _, after = buy.SweepState()
    H.eq("the pager resets the budget", after, 0)

    buy.SWEEP_MAX = 25
end

-- ---------------------------------------------------------------------------
H.section("a new search forgets the last one's sweep")
-- ---------------------------------------------------------------------------

do
    W.queries = {}
    W.queryOpen = true
    buy.Search("[Silk Cloth]")
    answer(junkPage(50), 150)
    local _, steps = buy.SweepState()
    H.eq("one page skipped", steps, 1)

    W.queryOpen = true
    buy.Search("cloth")
    local sweeping, steps2, stop2 = buy.SweepState()
    H.eq("a new search starts the count over", steps2, 0)
    H.check("...and is not mid-sweep", not sweeping)
    H.isNil("...and has no stale reason to report", stop2)
end

-- ---------------------------------------------------------------------------
H.section("what the status line says")
-- ---------------------------------------------------------------------------

-- MID-SWEEP. The player must be able to tell "still looking" from "stopped
-- looking" -- both leave a page with no rows on it.
H.eq("mid-sweep names the page and the count",
     ui.SweepStatus(true, 2, "advance", 2, 277),
     "No matches on page 3/277 \226\128\148 checking the next one (2 skipped)")

-- STOPPED AT THE BUDGET. Names the button, because pressing it is the whole
-- remedy and nothing else on screen says so.
do
    local t = ui.SweepStatus(false, 25, "limit", 24, 277)
    H.check("the budget message names the pager",
            string.find(t, "\226\150\182", 1, true) ~= nil, t)
    H.check("...and says how far it got",
            string.find(t, "25 pages", 1, true) ~= nil, t)
end

H.eq("running out of pages says so",
     ui.SweepStatus(false, 4, "end", 9, 10),
     "No matches in the last 4 pages \226\128\148 that was the last page")

-- NOTHING TO SAY. A one-page search that ended where it started gets the
-- ordinary "0 match(es)" line, not a report about a sweep that never ran.
H.isNil("a search that never swept says nothing",
        ui.SweepStatus(false, 0, "end", 0, 1))
H.isNil("nor does a page that matched",
        ui.SweepStatus(false, 0, "matched", 0, 10))
H.isNil("nor does one the server matched nothing for",
        ui.SweepStatus(false, 0, "empty", 0, 1))
H.isNil("nor does the feature switched off",
        ui.SweepStatus(false, 0, "off", 0, 10))

-- ---------------------------------------------------------------------------
H.section("the note on the line that DID find something")
-- ---------------------------------------------------------------------------

H.eq("nothing skipped adds nothing", ui.SkippedNote(0), "")
H.eq("...nor does nil", ui.SkippedNote(nil), "")
H.eq("one page is singular", ui.SkippedNote(1), " \226\128\162 1 page skipped")
H.eq("two are plural", ui.SkippedNote(2), " \226\128\162 2 pages skipped")

os.exit(H.report("sweep"))
