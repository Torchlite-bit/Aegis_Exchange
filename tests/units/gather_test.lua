-- Aegis: Exchange -- tests/units/gather_test.lua
--
-- A category browse gathers every page into one list.
--
-- REPORTED as "browsing Projectile > Bullet doesn't list all the ammo types".
-- Aegis listed ONE page -- 50 auctions -- and page 1 of Bullet held five kinds
-- of ammo, grouped into five rows, with the rest on pages 2 to 6.
--
-- What this pins:
--   * only a CATEGORY browse gathers; a name search keeps one page at a time;
--   * every page still goes through CanSendAuctionQuery() (HARD RULE 10);
--   * it is bounded, and the pager moves a window of pages;
--   * a page read again REPLACES what it held;
--   * buying or bidding on a row from a page the client is not holding asks
--     for that page first and finds the auction by fingerprint -- never a
--     blind index into whatever page happens to be loaded.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)
local buy = A.buy

-- A listing as the client holds it on a page.
local function lot(name, buyout)
    return { name = name, count = 1, buyout = buyout, minBid = 1,
             owner = "Someone", level = 1, quality = 1, timeLeft = 4 }
end

-- Tick until the next query goes out, then answer it.
local function answer(rows, total)
    W.queryOpen = true
    local before = table.getn(W.queries)
    W.TickUntil(buy.driver,
        function() return table.getn(W.queries) > before end, 50)
    W.SetPage(rows, total)
    buy.ReadPage()
end

-- The page the most recent query asked for.
local function lastPage()
    local q = W.queries[table.getn(W.queries)]
    return q and q.page
end

-- How many queries the driver sends when left alone, gate open.
local function queriesAfterTicking()
    W.queryOpen = true
    local before = table.getn(W.queries)
    for i = 1, 30 do W.Tick(buy.driver) end
    return table.getn(W.queries) - before
end

local function names(rows)
    local out = {}
    for i = 1, table.getn(rows or {}) do out[rows[i].name] = rows[i] end
    return out
end

local function search(text)
    buy.batch = { active = false }
    buy.find = nil
    buy.state.phase = "idle"
    W.queries = {}
    W.bids = {}
    W.money = 10000000
    W.queryOpen = true
    buy.Search(text)
end

-- Three pages of a category, two lots on each (a total of 150 auctions is
-- three pages of 50 as far as the page count is concerned).
local P = {
    [0] = { lot("Rough Arrow", 10),   lot("Sharp Arrow", 20) },
    [1] = { lot("Razor Arrow", 30),   lot("Jagged Arrow", 40) },
    [2] = { lot("Thorium Headed Arrow", 50), lot("Doomshot", 60) },
}

-- ---------------------------------------------------------------------------
H.section("Only a CATEGORY browse gathers")
-- ---------------------------------------------------------------------------

H.eq("a class browse gathers", buy.ShouldGather(buy.CompileQuery("weapon")), true)
H.eq("a name search does not", buy.ShouldGather(buy.CompileQuery("Linen Cloth")),
     false)
H.eq("an exact item does not (the Crafting tab's searches)",
     buy.ShouldGather(buy.CompileQuery("[Silk Cloth]")), false)
H.eq("an OR search does not -- it already rolls term by term",
     buy.ShouldGather(buy.CompileQuery("weapon;armor")), false)
H.eq("nothing does not", buy.ShouldGather(nil), false)

-- ---------------------------------------------------------------------------
H.section("Every page of a category lands in one list")
-- ---------------------------------------------------------------------------

search("weapon")
answer(P[0], 150)
H.eq("page 1 is in the list", table.getn(buy.state.rows), 2)
local g = buy.GatherState()
H.check("it knows how far it has to go", g and g.span == 3 and g.read == 1,
        g and (g.read .. "/" .. g.span) or "no state")
H.eq("...and is not done", g and g.done, false)

-- THE GATE. A shut gate holds the next page back, however eager the gather.
W.queryOpen = false
local held = table.getn(W.queries)
for i = 1, 20 do W.Tick(buy.driver) end
H.eq("with the gate shut, nothing is sent", table.getn(W.queries), held)

answer(P[1], 150)
H.eq("...and when it opens, page 2 is asked for", lastPage(), 1)
H.eq("page 2 joins page 1", table.getn(buy.state.rows), 4)
answer(P[2], 150)
H.eq("page 3 joins them", lastPage(), 2)
local all = names(buy.state.rows)
H.eq("six lots, one list", table.getn(buy.state.rows), 6)
H.check("the first page's lots are still there", all["Rough Arrow"] ~= nil)
H.check("...and the last page's", all["Doomshot"] ~= nil)
H.eq("each row remembers its page", all["Doomshot"] and all["Doomshot"].page, 2)
H.eq("...page 1's too", all["Rough Arrow"] and all["Rough Arrow"].page, 0)
H.eq("cheapest first across pages", buy.state.rows[1].name, "Rough Arrow")
g = buy.GatherState()
H.eq("done", g and g.done, true)
H.eq("...and it stops asking", queriesAfterTicking(), 0)

-- ---------------------------------------------------------------------------
H.section("A page read again REPLACES what it held")
-- ---------------------------------------------------------------------------

-- After a purchase the page is read again (see the end of buy.ReadPage). The
-- bought lot must leave the list, not linger beside the fresh copy.
buy.FetchPage(1)
answer({ lot("Jagged Arrow", 40) }, 149)
all = names(buy.state.rows)
H.check("the lot that is gone left the list", all["Razor Arrow"] == nil)
H.check("...what is still there stayed", all["Jagged Arrow"] ~= nil)
H.eq("...and nothing was counted twice", table.getn(buy.state.rows), 5)

-- ---------------------------------------------------------------------------
H.section("A name search keeps one page at a time")
-- ---------------------------------------------------------------------------

search("Arrow")
answer(P[0], 150)
H.isNil("no gather state", buy.GatherState())
H.eq("...and no second page is fetched on its own", queriesAfterTicking(), 0)

-- ---------------------------------------------------------------------------
H.section("Bounded: a window of pages, moved by the pager")
-- ---------------------------------------------------------------------------

local realMax = buy.GATHER_MAX
buy.GATHER_MAX = 2
search("weapon")
answer(P[0], 250)                       -- five pages on the server
answer(P[1], 250)
g = buy.GatherState()
H.check("it stops at the window's edge", g and g.done and g.to == 1,
        g and tostring(g.to) or "no state")
H.eq("...without asking for page 3", queriesAfterTicking(), 0)

H.check("the pager moves on a window", buy.NextPage())
answer(P[2], 250)
H.eq("the next window starts at page 3", lastPage(), 2)
all = names(buy.state.rows)
H.check("...and holds that window's lots, not the last one's",
        all["Doomshot"] ~= nil and all["Rough Arrow"] == nil)
answer(P[0], 250)                       -- page 4 comes on its own
H.eq("...the whole window", lastPage(), 3)

buy.PrevPage()
answer(P[0], 250)
H.eq("and back", lastPage(), 0)
buy.GATHER_MAX = realMax

-- ---------------------------------------------------------------------------
H.section("A sweep does not move the page under a gather")
-- ---------------------------------------------------------------------------

H.eq("gathering switches the sweep off",
     buy.SweepDecision({ enabled = true, matched = 0, rawTotal = 500,
                         page = 0, totalPages = 10, termIndex = 1,
                         totalTerms = 1, steps = 0, limit = 25,
                         gather = true }), "off")

-- ---------------------------------------------------------------------------
H.section("Which pages to look on")
-- ---------------------------------------------------------------------------

-- An auction moves to an EARLIER page when something ahead of it sells.
H.listEq("page 3, then the page before it", buy.CandidatePages({ 3 }), { 2, 3 })
H.listEq("page 1 has only itself", buy.CandidatePages({ 0 }), { 0 })
H.listEq("several, merged and ordered", buy.CandidatePages({ 3, 0, 3 }),
         { 0, 2, 3 })
H.listEq("none", buy.CandidatePages(nil), {})

-- ---------------------------------------------------------------------------
H.section("A Buyout on a row from a page the client is not holding")
-- ---------------------------------------------------------------------------

search("weapon")
answer(P[0], 150)
answer(P[1], 150)
answer(P[2], 150)                       -- the client now holds page 3
local rough = names(buy.state.rows)["Rough Arrow"]
H.eq("(the row is from page 1)", rough and rough.page, 0)

local result
local ok = buy.BuyoutAnywhere(rough, function(done, why) result = { done, why } end)
H.check("the buyout is accepted", ok)
H.eq("...but nothing is bought blind from the page in hand",
     table.getn(W.bids), 0)
-- Page 1 again -- and the lot has moved down one slot since it was read.
answer({ lot("Sharp Arrow", 20), lot("Rough Arrow", 10) }, 150)
H.eq("its page was asked for", W.queries[table.getn(W.queries)].page, 0)
H.eq("it was bought", table.getn(W.bids), 1)
H.eq("...at the index its page gives it NOW", W.bids[1] and W.bids[1].index, 2)
H.eq("...at its price", W.bids[1] and W.bids[1].amount, 10)
H.check("...and the caller was told", result and result[1] == true,
        result and tostring(result[2]) or "not told")

-- The lot moved to the page BEFORE the one it was read from.
search("weapon")
answer(P[0], 150)
answer(P[1], 150)
answer(P[2], 150)
local doom = names(buy.state.rows)["Doomshot"]
result = nil
buy.FetchPage(0)                        -- the client wanders off to page 1
answer(P[0], 150)
buy.BuyoutAnywhere(doom, function(done, why) result = { done, why } end)
answer({ lot("Razor Arrow", 30) }, 149)                -- page 2: not here
answer({ lot("Thorium Headed Arrow", 50) }, 149)       -- page 3: gone too...
H.check("not on its page or the one before: the caller hears it is gone",
        result and result[1] == false and result[2] ~= nil,
        result and tostring(result[2]) or "not told")
H.eq("...and nothing was bought", table.getn(W.bids), 0)
H.isNil("...and the hunt is over", buy.find)

search("weapon")
answer(P[0], 150)
answer(P[1], 150)
answer(P[2], 150)
doom = names(buy.state.rows)["Doomshot"]
result = nil
buy.FetchPage(0)
answer(P[0], 150)
buy.BuyoutAnywhere(doom, function(done, why) result = { done, why } end)
answer({ lot("Jagged Arrow", 40), lot("Doomshot", 60) }, 149)  -- page 2 has it
H.eq("found on the page before the one it was read from", table.getn(W.bids), 1)
H.eq("...at its index there", W.bids[1] and W.bids[1].index, 2)

-- THE PAGE IN HAND IS READ AGAIN before it is allowed to say "not here". The
-- list can be ahead of the client's copy of a page (the 1.54.20 report), so a
-- row missing from the copy in hand is looked for on a FRESH read of it.
search("Arrow")
answer(P[0], 150)
local roughHere = names(buy.state.rows)["Rough Arrow"]
W.SetPage({ lot("Sharp Arrow", 20) })   -- the client's copy has lost it
result = nil
buy.BuyoutAnywhere(roughHere, function(done2) result = done2 end)
H.eq("not bought from a copy that does not have it", table.getn(W.bids), 0)
H.isNil("...and not called gone either", result)
answer({ lot("Sharp Arrow", 20), lot("Rough Arrow", 10) }, 150)
H.eq("a fresh read of the same page finds it", table.getn(W.bids), 1)
H.eq("...at its index there", W.bids[1] and W.bids[1].index, 2)

-- On the page in hand, with nothing in flight: immediate, no query.
search("Arrow")
answer(P[0], 150)
local sharp = names(buy.state.rows)["Sharp Arrow"]
local sent = table.getn(W.queries)
result = nil
buy.BuyoutAnywhere(sharp, function(done) result = done end)
H.eq("a row on the page in hand is bought at once", table.getn(W.bids), 1)
H.eq("...without asking for anything", table.getn(W.queries), sent)
H.eq("...and the caller is told at once", result, true)

-- ---------------------------------------------------------------------------
H.section("A Bid on a row from another page")
-- ---------------------------------------------------------------------------

search("weapon")
answer(P[0], 150)
answer(P[1], 150)
answer(P[2], 150)
local razor = names(buy.state.rows)["Razor Arrow"]
buy.BidAnywhere(razor, 5, function() end)
H.eq("nothing is bid blind", table.getn(W.bids), 0)
answer(P[1], 150)
H.eq("its page is asked for, then the bid goes in", table.getn(W.bids), 1)
H.eq("...at the index there", W.bids[1] and W.bids[1].index, 1)
H.eq("...for the amount asked", W.bids[1] and W.bids[1].amount, 5)

-- ---------------------------------------------------------------------------
H.section("A multi-buyout reaches every page it was ticked on")
-- ---------------------------------------------------------------------------

search("weapon")
answer(P[0], 150)
answer(P[1], 150)
answer(P[2], 150)                       -- holding page 3
local list = names(buy.state.rows)
local picks = { list["Rough Arrow"], list["Doomshot"] }
local done
buy.StartBatch(picks, function(b, w, s, why) done = { b, why } end)
-- Doomshot is on the page in hand, so it goes first.
H.eq("what is on the page in hand is bought first", table.getn(W.bids), 1)
H.eq("...Doomshot", W.bids[1] and W.bids[1].amount, 60)
-- The purchase's own read: page 3 without Doomshot. Rough Arrow is not here,
-- so its page is asked for.
answer({ lot("Thorium Headed Arrow", 50) }, 149)
answer(P[0], 149)
H.eq("then its page is fetched and the rest bought", table.getn(W.bids), 2)
H.eq("...Rough Arrow, at its index there", W.bids[2] and W.bids[2].index, 1)
answer({ lot("Sharp Arrow", 20) }, 148)          -- the last purchase's read
H.check("the batch finished clean", done and done[1] == 2 and done[2] == nil,
        done and (tostring(done[1]) .. " " .. tostring(done[2])) or "running")

-- A ticked lot that is on none of its pages stops the batch, as it always
-- has -- after looking, not before.
search("weapon")
answer(P[0], 150)
answer(P[1], 150)
answer(P[2], 150)
list = names(buy.state.rows)
done = nil
buy.StartBatch({ list["Rough Arrow"] },
    function(b, w, s, why) done = { b, why } end)
answer({ lot("Sharp Arrow", 20) }, 149)         -- page 1: gone
H.check("gone from every page it could be on: stopped, and said why",
        done and done[1] == 0 and done[2] ~= nil,
        done and tostring(done[2]) or "running")
H.eq("...nothing bought", table.getn(W.bids), 0)

-- ---------------------------------------------------------------------------
H.section("A purchase comes before the next gathered page")
-- ---------------------------------------------------------------------------

search("weapon")
answer(P[0], 150)                       -- the gather now wants page 2
local sharpRow = names(buy.state.rows)["Sharp Arrow"]
done = nil
buy.StartBatch({ sharpRow }, function(b, w, s, why) done = { b, why } end)
H.eq("nothing bought while a page is in flight", table.getn(W.bids), 0)
answer(P[1], 150)                       -- page 2 lands; Sharp is on page 1
answer(P[0], 150)                       -- the batch fetches page 1 and buys
H.eq("the batch fetched its page and bought", table.getn(W.bids), 1)
H.eq("...page 1 was asked for before page 3", lastPage(), 0)
answer({ lot("Rough Arrow", 10) }, 149) -- the purchase's read ends the batch
H.check("the batch finished", done ~= nil and done[1] == 1)
answer({ lot("Rough Arrow", 10) }, 149) -- the page a purchase leaves behind
answer(P[2], 149)                       -- ...and THEN the gather carries on
H.eq("the gather picked up where it left off", lastPage(), 2)
H.eq("...and finished", buy.GatherState().done, true)

-- ---------------------------------------------------------------------------
H.section("A scan starting mid-gather pauses it, and it resumes")
-- ---------------------------------------------------------------------------

-- The scan reads the next list update as ITS reply, so nothing of ours may go
-- out while it queries -- and the gather must not simply die, or the list
-- sits at "reading page 2 of 3" for good.
search("weapon")
local realRunning = A.scan.IsRunning
-- Page 1's query goes out; the scan starts before its reply is read -- so the
-- gather decides about page 2 while the scan holds the channel.
W.queryOpen = true
W.TickUntil(buy.driver, function() return table.getn(W.queries) > 0 end, 50)
A.scan.IsRunning = function() return true end
W.SetPage(P[0], 150)
buy.ReadPage()
H.eq("while a scan queries, the next page is held back",
     queriesAfterTicking(), 0)
H.eq("...but still owed", buy.GatherState().done, false)
A.scan.IsRunning = realRunning
answer(P[1], 150)
H.eq("when the scan stops, it goes out", lastPage(), 1)
answer(P[2], 150)
H.eq("...and the gather finishes", buy.GatherState().done, true)

-- ---------------------------------------------------------------------------
H.section("A hunt that can no longer finish is called off, out loud")
-- ---------------------------------------------------------------------------

search("weapon")
answer(P[0], 150)
answer(P[1], 150)
answer(P[2], 150)
result = nil
buy.BuyoutAnywhere(names(buy.state.rows)["Rough Arrow"],
    function(ok2, why) result = { ok2, why } end)
H.check("(a hunt is on)", buy.find ~= nil)
buy.Search("armor")
H.check("a new search calls it off and says so",
        result and result[1] == false and result[2] ~= nil,
        result and tostring(result[2]) or "not told")
H.isNil("...and it is over", buy.find)

search("weapon")
answer(P[0], 150)
answer(P[1], 150)
result = nil
buy.BuyoutAnywhere(names(buy.state.rows)["Rough Arrow"],
    function(ok2, why) result = { ok2, why } end)
W.FireEvent(A.frame, "AUCTION_HOUSE_CLOSED")
H.check("closing the auction house calls it off and says so",
        result and result[1] == false and result[2] ~= nil,
        result and tostring(result[2]) or "not told")
H.isNil("...and it is over", buy.find)

-- ---------------------------------------------------------------------------
H.section("What the status line and pager say")
-- ---------------------------------------------------------------------------

-- Pure, in ui/frame.lua, which no suite loads -- lifted out and run here.
ui = {}
do
    local f = assert(io.open("ui/frame.lua", "r"), "run this from the repo root")
    local src = f:read("*a")
    f:close()
    for _, sig in ipairs({ "function ui.GatherNote(",
                           "function ui.GatherPageText(" }) do
        local at = assert(string.find(src, sig, 1, true), "did not find " .. sig)
        local stop = string.find(src, "\nend\n", at, true)
        assert(loadstring(string.sub(src, at, stop + 3), sig))()
    end
end

local B = "\226\128\162"
H.eq("still reading", ui.GatherNote({ from = 0, to = 5, read = 3, span = 6,
                                      totalPages = 6, done = false }),
     " " .. B .. " reading page 4 of 6\226\128\166")
H.eq("all of it", ui.GatherNote({ from = 0, to = 5, read = 6, span = 6,
                                  totalPages = 6, done = true }),
     " " .. B .. " all 6 pages")
H.eq("a window with more beyond it",
     ui.GatherNote({ from = 0, to = 19, read = 20, span = 20,
                     totalPages = 294, done = true, max = 20 }),
     " " .. B .. " pages 1\226\128\14720 of 294 \226\128\148 \226\150\182 for the next 20")
H.eq("...the last window names only what is left",
     ui.GatherNote({ from = 280, to = 289, read = 10, span = 10,
                     totalPages = 294, done = true, max = 10 }),
     " " .. B .. " pages 281\226\128\147290 of 294 \226\128\148 \226\150\182 for the next 4")
H.eq("one page says nothing", ui.GatherNote({ from = 0, to = 0, read = 1,
     span = 1, totalPages = 1, done = true }), "")
H.eq("not gathering says nothing", ui.GatherNote(nil), "")
H.eq("the pager names the window",
     ui.GatherPageText({ from = 0, to = 5, totalPages = 6 }),
     "Pages 1\226\128\1476 / 6")
H.eq("...one page as one page",
     ui.GatherPageText({ from = 0, to = 0, totalPages = 1 }), "Page 1 / 1")
H.isNil("...and leaves the ordinary pager alone otherwise",
        ui.GatherPageText(nil))

-- ...and the Buy tab actually says them, and buys through the path that can
-- reach another page. Source checks: the functions above are only half of it.
do
    local f = assert(io.open("ui/frame.lua", "r"))
    local src = f:read("*a")
    f:close()
    local function bodyOf(head)
        local at = string.find(src, head, 1, true)
        if not at then return "" end
        local stop = string.find(src, "\nend\n", at, true)
        return string.sub(src, at, stop or -1)
    end
    local list = bodyOf("function ui.UpdateBuyList(")
    H.check("the match count carries the gather note",
            string.find(list, "headline = headline .. ui.GatherNote(gather)",
                        1, true) ~= nil)
    H.check("the pager names the window",
            string.find(list, "ui.GatherPageText(A.buy.GatherState())",
                        1, true) ~= nil)
    H.check("Buyout goes through BuyoutAnywhere",
            string.find(bodyOf("function ui.DoBuyout("),
                        "A.buy.BuyoutAnywhere(row,", 1, true) ~= nil)
end

os.exit(H.report("gather"))
