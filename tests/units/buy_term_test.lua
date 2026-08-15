-- Aegis: Exchange -- tests/units/buy_term_test.lua
--
-- core/buy.lua's search-term language: ParseTerm (text -> term), TermToQuery
-- (term -> text) and the round trip between them, plus the 1.12
-- QueryAuctionItems contract the term is ultimately turned into.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)
local buy, util = A.buy, A.util

-- ---------------------------------------------------------------------------
H.section("Plain names")
-- ---------------------------------------------------------------------------

local t = buy.ParseTerm("linen cloth")
H.eq("a bare term is just a name", t.name, "linen cloth")
H.eq("no flags are set by a plain name", t.exact, false)
H.eq("...nor usable", t.usable, false)
H.eq("...nor buyout-only", t.buyoutOnly, false)
H.isNil("...nor a quality", t.quality)

local empty = buy.ParseTerm("")
H.survives("an empty term parses without error", function() buy.ParseTerm("") end)
H.check("an empty term yields a term table", empty ~= nil, tostring(empty))

-- ---------------------------------------------------------------------------
H.section("Flags")
-- ---------------------------------------------------------------------------

t = buy.ParseTerm("linen/exact")
H.eq("exact is recognised", t.exact, true)
H.eq("...and does not eat the name", t.name, "linen")

t = buy.ParseTerm("linen/usable/buyout")
H.eq("usable is recognised", t.usable, true)
H.eq("buyout is recognised", t.buyoutOnly, true)

-- Flags are case-insensitive: the term box is free text and users type how
-- they type.
t = buy.ParseTerm("linen/EXACT")
H.eq("flags are case-insensitive", t.exact, true)

-- ---------------------------------------------------------------------------
H.section("stack -- explicit size vs. full-stack-only")
-- ---------------------------------------------------------------------------

-- "stack/20" is an EXPLICIT size and needs no item data, which is the whole
-- point: it works on the first search however cold the client's cache is.
t = buy.ParseTerm("linen/stack/20")
H.eq("an explicit stack size is captured", t.stackSize, 20)
H.eq("...and does not set the bare stack flag", t.stackOnly, false)

-- Bare "stack" means "full stacks only", which DOES need item data and is why
-- unknown-stack rows get counted and reported rather than silently dropped.
t = buy.ParseTerm("linen/stack")
H.eq("bare stack sets stackOnly", t.stackOnly, true)
H.isNil("...with no explicit size", t.stackSize)

-- A non-numeric follower is not a size; it must fall back to the bare flag
-- rather than consuming the next token.
t = buy.ParseTerm("linen/stack/exact")
H.eq("a non-numeric follower leaves stackOnly set", t.stackOnly, true)
H.eq("...and the follower is still parsed as its own flag", t.exact, true)

-- ---------------------------------------------------------------------------
H.section("quality and level")
-- ---------------------------------------------------------------------------

t = buy.ParseTerm("linen/quality/3")
H.eq("a numeric quality is captured", t.quality, 3)

t = buy.ParseTerm("sword/level/20-40")
H.eq("a level RANGE sets the minimum", t.minLevel, 20)
H.eq("...and the maximum", t.maxLevel, 40)

t = buy.ParseTerm("sword/level/25")
H.eq("a single level sets the minimum", t.minLevel, 25)

-- ---------------------------------------------------------------------------
H.section("tooltip consumes exactly ONE token")
-- ---------------------------------------------------------------------------

-- This is load-bearing. tooltip used to swallow the rest of the term, which is
-- why "tooltip must be emitted last" was once a rule. It takes one token now,
-- so anything after it still parses.
t = buy.ParseTerm("cloak/tooltip/stamina/exact")
H.eq("the flag AFTER a tooltip clause is still parsed", t.exact, true)
H.check("the tooltip clause was recorded",
        table.getn(t.post) > 0, table.getn(t.post))
H.eq("the tooltip clause holds only its own token",
     t.post[1].value, "stamina")

-- ---------------------------------------------------------------------------
H.section("Round trip: text -> term -> text -> term")
-- ---------------------------------------------------------------------------

-- TermsEqual is the real comparison (it is what decides whether a saved search
-- matches the current one), so the round trip is asserted with it rather than
-- by string equality -- spelling may differ, meaning may not.
local cases = {
    "linen cloth",
    "linen/exact",
    "linen/usable",
    "linen/buyout",
    "linen/stack/20",
    "linen/stack",
    "linen/quality/3",
    "sword/level/20-40",
    "cloak/tooltip/stamina",
    "linen/exact/usable/buyout/quality/2",
}
for i = 1, table.getn(cases) do
    local original = buy.ParseTerm(cases[i])
    local text     = buy.TermToQuery(original)
    local reparsed = buy.ParseTerm(text)
    H.check("round trip preserves meaning: " .. cases[i],
            buy.TermsEqual(original, reparsed),
            cases[i] .. "  ->  " .. text)
end

-- TermsEqual must be able to say NO, or every round-trip check above is
-- vacuous.
H.check("TermsEqual distinguishes different terms",
        not buy.TermsEqual(buy.ParseTerm("linen"),
                           buy.ParseTerm("wool")),
        "two different terms compared equal")
H.check("TermsEqual distinguishes a flag difference",
        not buy.TermsEqual(buy.ParseTerm("linen"),
                           buy.ParseTerm("linen/exact")),
        "exact was ignored in the comparison")

-- ---------------------------------------------------------------------------
H.section("The 1.12 QueryAuctionItems contract")
-- ---------------------------------------------------------------------------

-- tests/support/wow.lua ASSERTS the signature: name/minLevel/maxLevel must be
-- STRINGS (the stock browse UI sends GetText() results, and servers may
-- silently ignore a query with nils in those slots -- which presents as a scan
-- that spins forever on "Requesting first page..."), and page is 0-INDEXED.
-- So any query the engine sends is checked simply by being sent.

W.queries = {}
W.queryOpen = true
H.check("the query gate starts open", CanSendAuctionQuery(),
        tostring(CanSendAuctionQuery()))

-- buy.Search only ARMS the driver; the query itself is sent from the driver's
-- OnUpdate, gated on CanSendAuctionQuery(). That is the throttle, so it is
-- also the reason a test has to tick the client rather than just call Search.
H.survives("a plain search arms the driver", function()
    buy.Search("linen cloth")
end)
H.eq("no query is sent before the client ticks", table.getn(W.queries), 0)

local settled = W.TickUntil(buy.driver,
                            function() return table.getn(W.queries) > 0 end, 50)
H.check("a query was sent once the client ticked", settled,
        table.getn(W.queries))

local q = W.queries[1]
if q then
    H.eq("name is a string", type(q.name), "string")
    H.eq("minLevel is a string", type(q.minLevel), "string")
    H.eq("maxLevel is a string", type(q.maxLevel), "string")
    H.check("page is 0-indexed", q.page == nil or q.page == 0, tostring(q.page))
end

-- The gate is the authority, never a wall-clock timer. After a query the
-- client shuts it, and nothing may query again until it reopens.
H.eq("the client shut the gate after the query", CanSendAuctionQuery(), false)

os.exit(H.report("buy.term"))
