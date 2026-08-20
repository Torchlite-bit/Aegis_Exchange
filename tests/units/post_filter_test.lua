-- Aegis: Exchange -- tests/units/post_filter_test.lua
--
-- The post-filter components that narrow on data the PAGE already carries:
-- min-level, max-level, rarity, seller and left. Each is a predicate over a
-- row buy.ReadPage has already built, so every one of them is exercised
-- through the real compile path -- buy.ParseTerm -> buy.CompileTerm -> the
-- filter closure -- rather than by calling an internal.
--
-- WHAT THIS SUITE IS REALLY FOR. Two of these can fail to ANSWER: `owner` is
-- nil until the client resolves the name (CLAUDE.md rule 8) and `timeLeft` is
-- guarded because a server may not report it. A filter that throws those rows
-- away in silence is indistinguishable from a broken filter -- which is
-- exactly how bare `stack` was reported -- so "counted and confessed" is
-- asserted here as hard as the matching itself.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)
local buy = A.buy

-- "Override this field to nil."
--
-- `Row({ owner = nil })` sets no key at all -- a table constructor with a nil
-- value stores nothing, so pairs() never sees it and the default survives
-- untouched. The first draft of this file did exactly that, and the four
-- assertions about unresolved owners passed against a row that HAD one. A
-- sentinel is the only way to say "absent" through a table.
local NIL = {}

-- A page row, shaped as buy.ReadPage builds one. Overrides are merged so each
-- case names only the field it is about.
local function Row(over)
    local r = {
        index = 1, name = "Silk Cloth", count = 1,
        quality = 3, level = 45, owner = "Bobby", timeLeft = 2,
        buyout = 1000, unit = 1000, minBid = 900, bidAmount = 0,
    }
    for k, v in pairs(over or {}) do
        if v == NIL then r[k] = nil else r[k] = v end
    end
    return r
end

-- Run a query's filter over one row. Returns whether it kept the row, plus
-- the unanswered tally, because for half these components those are the same
-- question asked twice.
local function keeps(query, row)
    local compiled = buy.CompileTerm(buy.ParseTerm(query))
    local stats = {}
    local kept = compiled.filter(row or Row(), stats) and true or false
    local blind, who = buy.UnansweredSummary(stats)
    return kept, blind, who
end

local function kept(query, row) local k = keeps(query, row); return k end

-- ---------------------------------------------------------------------------
H.section("min-level / max-level bound the row's own level")
-- ---------------------------------------------------------------------------

H.check("min-level keeps a row at the bound", kept("silk/min-level/45"), "")
H.check("min-level keeps a row above it", kept("silk/min-level/40"), "")
H.check("min-level drops a row below it",
        not kept("silk/min-level/50"), "level 45 survived min-level/50")

H.check("max-level keeps a row at the bound", kept("silk/max-level/45"), "")
H.check("max-level keeps a row below it", kept("silk/max-level/60"), "")
H.check("max-level drops a row above it",
        not kept("silk/max-level/40"), "level 45 survived max-level/40")

-- The pair is what makes a band, and a band is the thing the server-side
-- level filter cannot be OR'd or negated into.
H.check("the pair brackets a range",
        kept("silk/min-level/40/max-level/50"), "")
H.check("...and excludes what falls outside it",
        not kept("silk/min-level/40/max-level/44"), "")

-- Level 0 is a real value (no requirement), not a missing one.
H.check("a level-0 row passes min-level/0",
        kept("silk/min-level/0", Row({ level = 0 })), "")
H.check("...and is dropped by min-level/1",
        not kept("silk/min-level/1", Row({ level = 0 })), "")

-- ---------------------------------------------------------------------------
H.section("rarity is EXACT, and that is the whole point of it")
-- ---------------------------------------------------------------------------

-- The server-side `quality/N` is already the minimum -- the form's own "Min
-- Quality" -- so a post-filter minimum would be a second spelling of a thing
-- that already had one. Exact is what cannot otherwise be said.
H.check("rarity matches its own quality", kept("silk/rarity/rare"), "")
H.check("rarity does NOT match better than itself",
        not kept("silk/rarity/rare", Row({ quality = 4 })),
        "an epic passed rarity/rare -- that is a minimum, not an exact match")
H.check("rarity does not match worse either",
        not kept("silk/rarity/rare", Row({ quality = 2 })), "")

-- The same vocabulary as `quality`, because two spellings for one concept is
-- how a language starts to need a manual.
H.check("rarity takes an index too", kept("silk/rarity/3"), "")
H.check("...and poor is 0, not 'missing'",
        kept("silk/rarity/poor", Row({ quality = 0 })), "")

-- ---------------------------------------------------------------------------
H.section("seller matches a substring of the owner, case-insensitively")
-- ---------------------------------------------------------------------------

H.check("the whole name matches", kept("silk/seller/Bobby"), "")
H.check("a prefix matches", kept("silk/seller/Bob"), "")
H.check("case is ignored", kept("silk/seller/bOBbY"), "")
H.check("a different seller does not match",
        not kept("silk/seller/Alice"), "")

-- Plain find, never a pattern: a seller called "Mr.X" must not be a regex,
-- and "." must not match "Mrs".
H.check("the needle is plain text, not a pattern",
        not kept("silk/seller/B.bby"), "'.' was treated as a wildcard")
H.check("...and a real dotted name still matches itself",
        kept("silk/seller/Mr.X", Row({ owner = "Mr.Xavier" })), "")

-- ---------------------------------------------------------------------------
H.section("left is a bound: at most this much time remaining")
-- ---------------------------------------------------------------------------

-- 1..4 is Short / Medium / Long / Very Long, exactly as
-- GetAuctionItemTimeLeft reports it.
H.check("a medium row passes left/medium", kept("silk/left/medium"), "")
H.check("...and left/long", kept("silk/left/long"), "")
H.check("...but not left/short",
        not kept("silk/left/short"), "medium survived left/short")
H.check("a short row passes left/short",
        kept("silk/left/short", Row({ timeLeft = 1 })), "")

-- The English keys are the language and do not vary by locale -- a saved
-- search has to mean the same thing on a German client.
H.check("the index spelling works too", kept("silk/left/2"), "")
H.check("'very long' is one token", kept("silk/left/very long"), "")
H.check("...and so is 'verylong'", kept("silk/left/verylong"), "")

-- A bound composes, which is why it was chosen over an exact match: exactly
-- medium is still reachable.
H.check("exactly-medium is expressible",
        kept("silk/left/medium/not/left/short"), "")
H.check("...and excludes a short row",
        not kept("silk/left/medium/not/left/short", Row({ timeLeft = 1 })), "")

-- ---------------------------------------------------------------------------
H.section("percent and vendor-profit: the price DB decides")
-- ---------------------------------------------------------------------------

-- Seed the DB the way a scan would. RecordAuction keeps the daily MINIMUM and
-- MarketValue is a weighted median over the days, so one recording on one day
-- gives back exactly what went in.
A.db.RecordAuction(101, 1000, "Priced Thing")
A.db.SetVendor(102, 900)          -- a merchant pays 900 per unit
local priced = Row({ itemId = 101, unit = 1000 })

-- AT MOST this percentage of market. 1000 of 1000 is 100%.
H.check("percent keeps a row at the bound", kept("silk/percent/100", priced), "")
H.check("percent keeps a cheaper row",
        kept("silk/percent/100", Row({ itemId = 101, unit = 500 })), "")
H.check("percent drops a dearer one",
        not kept("silk/percent/100", Row({ itemId = 101, unit = 1500 })), "")
H.check("half price passes percent/50",
        kept("silk/percent/50", Row({ itemId = 101, unit = 500 })), "")
H.check("...and 51% of market does not",
        not kept("silk/percent/50", Row({ itemId = 101, unit = 510 })), "")

-- A ceiling composes: the other side is a `not` away.
H.check("not/percent finds what is OVER the line",
        kept("silk/not/percent/100", Row({ itemId = 101, unit = 1500 })), "")

-- vendor-profit: buy at `unit`, vendor at 900, keep the difference.
H.check("a 400-per-item margin passes vendor-profit/4s",
        kept("silk/vendor-profit/4s", Row({ itemId = 102, unit = 500 })), "")
H.check("...and exactly the asked-for margin passes too",
        kept("silk/vendor-profit/4s", Row({ itemId = 102, unit = 500 })), "")
H.check("a thinner margin does not",
        not kept("silk/vendor-profit/4s", Row({ itemId = 102, unit = 600 })), "")
H.check("nor does buying above vendor",
        not kept("silk/vendor-profit/1c", Row({ itemId = 102, unit = 1200 })), "")

-- Both figures are PER UNIT, which is the only comparison that survives
-- different stack sizes: a stack of 20 at 500 each is the same deal as one.
H.check("stack size does not change the answer",
        kept("silk/vendor-profit/4s",
             Row({ itemId = 102, unit = 500, count = 20, buyout = 10000 })), "")

-- ---------------------------------------------------------------------------
H.section("...and they confess what they do not know")
-- ---------------------------------------------------------------------------

-- An item the price DB has never seen cannot be judged. This is OUR ignorance,
-- fixable by scanning, so it is counted -- unlike a bid-only row below.
local unseen = Row({ itemId = 999, unit = 500 })
local pk, pblind, pwho = keeps("silk/percent/50", unseen)
H.check("an unpriced item does not match", not pk, "")
H.eq("...it is counted", pblind, 1)
H.eq("...and named", pwho, "percent")

local vk2, vblind, vwho = keeps("silk/vendor-profit/1s", unseen)
H.check("an item with no vendor price does not match", not vk2, "")
H.eq("...it is counted", vblind, 1)
H.eq("...and named", vwho, "vendor-profit")

-- A row we CAN judge is never counted, or the note appears on every search.
local _, none = keeps("silk/percent/100", priced)
H.eq("a priced row is not counted", none, 0)

-- THE DISTINCTION THIS TURNS ON. A bid-only auction has no unit price because
-- the seller set no buyout -- a fact about the auction, visible on the row,
-- that no amount of scanning changes. Confessing those would put the note on
-- nearly every search and it would stop meaning anything. Same treatment
-- max-unit-buy has always given them.
local bidOnly = Row({ itemId = 101, unit = NIL, buyout = 0 })
local bk, bblind = keeps("silk/percent/100", bidOnly)
H.check("a bid-only row does not match percent", not bk, "")
H.eq("...and is NOT confessed -- that is not our ignorance", bblind, 0)
local bk2, bblind2 = keeps("silk/vendor-profit/1c", bidOnly)
H.check("nor vendor-profit", not bk2, "")
H.eq("...and is not confessed either", bblind2, 0)

-- ---------------------------------------------------------------------------
H.section("The advice offered is advice that WORKS")
-- ---------------------------------------------------------------------------

-- Telling someone to search again for a vendor price sends them round a loop
-- that cannot succeed: 1.12's GetItemInfo has no sell price and the only
-- source is standing at a merchant. So the remedy is per component.
local function fixFor(query, row)
    local compiled = buy.CompileTerm(buy.ParseTerm(query))
    local stats = {}
    compiled.filter(row, stats)
    local _, _, fix = buy.UnansweredSummary(stats)
    return fix
end

H.eq("an unresolved seller: search again",
     fixFor("silk/seller/Bobby", Row({ owner = NIL })), "search again")
H.eq("an unpriced item: scan for it",
     fixFor("silk/percent/50", unseen), "scan to learn its price")
H.eq("an unknown vendor price: go to a merchant",
     fixFor("silk/vendor-profit/1s", unseen),
     "vendor prices are learned at a merchant")

-- Two kinds of ignorance with two different cures cannot be summed up in one
-- clause, and picking either would tell half the readers the wrong thing.
H.isNil("mixed causes offer NO advice rather than the wrong advice",
        fixFor("silk/seller/Bobby/or/vendor-profit/1s",
               Row({ owner = NIL, itemId = 999, unit = 500 })))

-- ---------------------------------------------------------------------------
H.section("A filter that cannot ANSWER says so")
-- ---------------------------------------------------------------------------

-- THE CASE THIS EXISTS FOR. owner is nil until the name resolves, so a fresh
-- page can hand `seller` fifty rows it cannot judge. Dropping them is right --
-- a positive filter cannot honestly keep what it cannot verify -- but doing
-- it silently would present as "seller finds nothing".
local blindOwner = Row({ owner = NIL })
local k, blind, who = keeps("silk/seller/Bobby", blindOwner)
H.check("an unresolved owner does not match", not k, "")
H.eq("...it is COUNTED", blind, 1)
H.eq("...and named", who, "seller")

k, blind, who = keeps("silk/left/short", Row({ timeLeft = NIL }))
H.check("an unreported time left does not match", not k, "")
H.eq("...it is counted", blind, 1)
H.eq("...and named", who, "left")

-- An empty owner string is the same case as nil, not a seller named "".
local _, blindEmpty = keeps("silk/seller/Bobby", Row({ owner = "" }))
H.eq("an empty owner counts as unanswered", blindEmpty, 1)

-- A row it CAN judge is never counted, or the note would appear on every
-- search and stop meaning anything.
local _, none = keeps("silk/seller/Bobby", Row())
H.eq("a row that can be judged is not counted", none, 0)
local _, noneLvl = keeps("silk/min-level/40", Row())
H.eq("...nor is a filter that never fails to answer", noneLvl, 0)

-- Two blind components that BOTH get asked name both, in a stable order -- a
-- sentence that reshuffles between repaints reads as a different problem each
-- time. `or` is used here because it is the shape that runs both.
local stats = {}
local both = buy.CompileTerm(buy.ParseTerm("silk/seller/Bobby/or/left/short"))
both.filter(Row({ owner = NIL, timeLeft = NIL }), stats)
local n2, who2 = buy.UnansweredSummary(stats)
H.eq("both blind components are counted", n2, 2)
H.eq("...and named in sorted order", who2, "left/seller")

-- A STACKED pair counts only the first, and that is correct rather than a
-- miscount: buy.CompilePost short-circuits, so a false `and` operand means
-- the next one is never asked. That skip is what keeps an or-chain from
-- running a tooltip scan it does not need, and the confession describes what
-- was actually evaluated rather than what might have been.
local andStats = {}
local chain = buy.CompileTerm(buy.ParseTerm("silk/seller/Bobby/left/short"))
chain.filter(Row({ owner = NIL, timeLeft = NIL }), andStats)
local n3, who3 = buy.UnansweredSummary(andStats)
H.eq("a short-circuited AND asks only the first", n3, 1)
H.eq("...and names only what it asked", who3, "seller")

H.eq("nothing to confess reports nothing", buy.UnansweredSummary({}), 0)
local _, emptyWho = buy.UnansweredSummary(nil)
H.eq("...and a missing stats table is not an error", emptyWho, "")

-- ---------------------------------------------------------------------------
H.section("The components compose with the combinators")
-- ---------------------------------------------------------------------------

-- Stacked clauses AND, which is the default nobody has to type.
H.check("two stacked clauses both have to hold",
        kept("silk/min-level/40/rarity/rare"), "")
H.check("...and one failing drops the row",
        not kept("silk/min-level/50/rarity/rare"), "")

H.check("or widens", kept("silk/min-level/50/or/rarity/rare"), "")
H.check("not excludes", not kept("silk/not/rarity/rare"), "")
H.check("...and keeps what it does not name",
        kept("silk/not/rarity/epic"), "")

-- ---------------------------------------------------------------------------
H.section("Values round-trip through the query string")
-- ---------------------------------------------------------------------------

-- By VALUE, not by spelling: `rarity/rare` is stored as 3 and comes back as
-- `rarity/3`, the same index the server-side `quality/2` already emits.
local cases = {
    "silk/min-level/40",
    "silk/max-level/60",
    "silk/rarity/rare",
    "silk/rarity/3",
    "silk/seller/Bobby",
    "silk/left/short",
    "silk/left/very long",
    "silk/min-level/40/max-level/60/rarity/3/left/medium",
    "silk/min-level/40/or/rarity/epic",
    "silk/percent/80",
    "silk/vendor-profit/5s",
    "silk/percent/80/vendor-profit/1g",
}
for i = 1, table.getn(cases) do
    local original = buy.ParseTerm(cases[i])
    local text     = buy.TermToQuery(original)
    local reparsed = buy.ParseTerm(text)
    H.check("round trip preserves meaning: " .. cases[i],
            buy.TermsEqual(original, reparsed),
            cases[i] .. "  ->  " .. text)
end

-- Time left goes back as a WORD. `left/1` round-trips perfectly well and is
-- unreadable in a saved search list, which is a cost paid by a person.
H.eq("left is written back in words",
     buy.TermToQuery(buy.ParseTerm("silk/left/2")), "silk/left/medium")
-- Money keeps its own spelling, which is the case that proves the emitter is
-- asking the value table rather than calling tostring on everything.
H.eq("a price is still written as a price",
     buy.TermToQuery(buy.ParseTerm("silk/max-unit-buy/5g")),
     "silk/max-unit-buy/5g")

-- ---------------------------------------------------------------------------
H.section("A value that does not parse is not a clause")
-- ---------------------------------------------------------------------------

-- It becomes NAME TEXT, exactly as `quality` and `level` already do. Silently
-- accepting it would build a clause that cannot mean anything, and a filter
-- matching nothing for an unexplained reason is the failure this addon keeps
-- having to fix.
local junk = buy.ParseTerm("silk/min-level/soon")
H.eq("an unparseable level adds no clause", table.getn(junk.post), 0)
H.check("...and the words survive as a name",
        string.find(junk.name, "min-level", 1, true) ~= nil, junk.name)

H.eq("an unparseable rarity adds no clause",
     table.getn(buy.ParseTerm("silk/rarity/shiny").post), 0)
H.eq("an unparseable time left adds no clause",
     table.getn(buy.ParseTerm("silk/left/eventually").post), 0)
H.eq("an unparseable percentage adds no clause",
     table.getn(buy.ParseTerm("silk/percent/cheap").post), 0)

-- A trailing % is what people type, so it is taken and dropped -- the sign is
-- punctuation, not data, and both spellings are the same clause.
H.check("percent accepts a % sign",
        buy.TermsEqual(buy.ParseTerm("silk/percent/80%"),
                       buy.ParseTerm("silk/percent/80")),
        buy.TermToQuery(buy.ParseTerm("silk/percent/80%")))
H.eq("...and writes it back without one",
     buy.TermToQuery(buy.ParseTerm("silk/percent/80%")), "silk/percent/80")
-- A price keeps its own spelling, which is what proves the emitter asks the
-- value table rather than calling tostring on everything.
H.eq("vendor-profit is written back as a price",
     buy.TermToQuery(buy.ParseTerm("silk/vendor-profit/5s")),
     "silk/vendor-profit/5s")
H.eq("a component with no value at all adds no clause",
     table.getn(buy.ParseTerm("silk/min-level").post), 0)

-- The components still stop the tooltip run-on, which is what keeps
-- "tooltip/stamina/min-level/40" meaning both things.
local run = buy.ParseTerm("cloak/tooltip/stamina/min-level/40")
local needles, mins = 0, 0
for i = 1, table.getn(run.post) do
    if run.post[i].kind == "tooltip" then needles = needles + 1 end
    if run.post[i].kind == "min-level" then mins = mins + 1 end
end
H.eq("the run-on stopped at the component", needles, 1)
H.eq("...which parsed as its own clause", mins, 1)

-- ---------------------------------------------------------------------------
H.section("The still-pending components narrow nothing, on purpose")
-- ---------------------------------------------------------------------------

-- `item` and `disenchant-profit` parse and round-trip so a query carrying one
-- survives an edit, but they must not filter -- an always-false placeholder
-- would empty the page. (`percent` and `vendor-profit` graduated in v1.25.0
-- and have their own section above.)
local pending = { "item", "disenchant-profit" }
for i = 1, table.getn(pending) do
    local p = pending[i]
    H.check(p .. " keeps every row", kept("silk/" .. p .. "/whatever"),
            "a pending component narrowed the search")
    H.eq(p .. " still records a clause",
         table.getn(buy.ParseTerm("silk/" .. p .. "/whatever").post), 1)
end

-- ---------------------------------------------------------------------------
H.section("The UI's pending list agrees with the engine's")
-- ---------------------------------------------------------------------------

-- TWO TABLES IN TWO FILES. core/buy.lua's PENDING_COMPONENT decides what the
-- parser treats as inert; ui.PENDING_COMPONENTS decides what the Builder
-- draws dim and labels "ignored". They are not the same table and nothing
-- makes them agree, so a component implemented in one and still listed in the
-- other either works while looking broken or looks fine while doing nothing.
--
-- Read out of the source rather than restated: this is a claim ABOUT the two
-- lists, and a copy here would be a third one to drift.
local uiPending = {}
do
    local f = assert(io.open("ui/frame.lua", "r"), "run from the repo root")
    local inside = false
    for line in f:lines() do
        if not inside then
            if string.find(line, "^ui%.PENDING_COMPONENTS = {") then
                inside = true
            end
        else
            if string.find(line, "^}") then break end
            local _, _, key, rhs = string.find(line,
                '^%s*%["([%w%-]+)%"%]%s*=%s*(.*)$')
            if key then uiPending[key] = rhs or "" end
        end
    end
    f:close()
end

-- Every name the UI dims must really narrow nothing...
local dimmed = 0
for kind, rhs in pairs(uiPending) do
    dimmed = dimmed + 1
    H.check(kind .. " is dimmed AND really inert",
            kept("silk/" .. kind .. "/whatever"),
            "the Builder draws it dim while it actually filters")
    -- ...and each carries its own REASON rather than a bare `true`. The two
    -- remaining ones are not the same kind of pending -- `item` is unbuilt,
    -- `disenchant-profit` is unbuildable with what 1.12 provides -- and one
    -- sentence for both is how the disenchant question gets asked again every
    -- few releases. See ROADMAP 3k.
    H.check(kind .. " explains WHY it is pending",
            string.find(rhs, '^"') ~= nil,
            "value is `" .. rhs .. "`, not a reason")
end
H.eq("the UI dims exactly the components the engine leaves inert",
     dimmed, table.getn(pending))
for i = 1, table.getn(pending) do
    H.check(pending[i] .. " is in the UI's list too", uiPending[pending[i]],
            "the engine ignores it but the Builder shows it as working")
end

-- ...and nothing that WORKS is listed. Checked from the other direction,
-- because the loop above cannot see a live component wrongly added.
local live = { "min-level", "max-level", "rarity", "seller", "left",
               "percent", "vendor-profit", "max-unit-buy", "min-unit-buy" }
for i = 1, table.getn(live) do
    H.check(live[i] .. " is NOT listed as pending", not uiPending[live[i]],
            "an implemented component is drawn dim and labelled ignored")
end

os.exit(H.report("post_filter"))
