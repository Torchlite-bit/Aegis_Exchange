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
H.section("tooltip does not need repeating")
-- ---------------------------------------------------------------------------

-- The run-on: plain tokens after a needle are MORE needles for the same
-- filter. Consecutive operands with no combinator are ANDed, which is what the
-- repeated spelling already meant -- so the two must parse to the same term.
local function needles(term)
    local out = {}
    for i = 1, table.getn(term.post) do
        if term.post[i].kind == "tooltip" then
            table.insert(out, term.post[i].value)
        end
    end
    return out
end

local long  = buy.ParseTerm("wristbands/tooltip/+3 stam/tooltip/+3 agi")
local short = buy.ParseTerm("wristbands/tooltip/+3 stam/+3 agi")
H.listEq("the short form collects both needles", needles(short),
         { "+3 stam", "+3 agi" })
H.check("both spellings parse to the SAME term",
        buy.TermsEqual(long, short),
        buy.TermToQuery(long) .. "  vs  " .. buy.TermToQuery(short))
H.eq("the name is not eaten by the run-on", short.name, "wristbands")

-- OLD SAVED SEARCHES. The long form is what every stored favourite and every
-- recent search on disk is written in, and it has to keep working exactly --
-- this is the one assertion that says an upgrade cannot break saved data.
H.listEq("the long form still collects both needles", needles(long),
         { "+3 stam", "+3 agi" })

-- More than two, because "the second one works" and "it keeps going" are
-- different claims.
H.listEq("a run of three is all needles",
         needles(buy.ParseTerm("cloak/tooltip/a/b/c")), { "a", "b", "c" })

-- WHERE THE RUN-ON STOPS. Every one of these is a token ParseTerm claims for
-- itself, and each must end the run rather than become a needle. The pairing
-- is deliberate: the second assertion proves the token really is part of the
-- parser's vocabulary, so a list that has drifted out of date fails loudly
-- instead of passing for the wrong reason.
local stoppers = {
    "exact", "usable", "buyout", "stack", "tooltip",
    "and", "or", "not", "quality", "level",
    "max-unit-buy", "min-unit-buy",
    "min-level", "max-level", "rarity", "seller", "left",   -- row filters
    "item", "percent", "vendor-profit",             -- still-pending ones
    "quality3", "stack20", "level20",               -- fused spellings
    "weapon",                                       -- a class name
}
for i = 1, table.getn(stoppers) do
    local kw = stoppers[i]
    local run = buy.ParseTerm("cloak/tooltip/keep/" .. kw)
    H.listEq("the run-on stops at " .. kw, needles(run), { "keep" })
    -- Asked against a BARE term, which is the state the run-on was in when it
    -- stopped -- "cloak" is name text and resolves no category. Asking `run`
    -- instead would be asking a different question, because a class the token
    -- itself set is already recorded there.
    H.check(kw .. " is really a keyword, not just an unrecognised word",
            buy.IsTermKeyword(kw, {}), "IsTermKeyword said no")
end

-- A subclass is a keyword only once its class is known, so it has to be asked
-- in position -- which is why IsTermKeyword takes the term.
H.listEq("a subclass stops the run once its class is set",
         needles(buy.ParseTerm("armor/tooltip/keep/cloth")), { "keep" })
H.check("...and is NOT a keyword with no class resolved",
        not buy.IsTermKeyword("cloth", {}), "claimed cloth outside a class")

-- THE TRADE, asserted rather than only documented: a needle that is a keyword
-- cannot be written bare any more.
local claimed = buy.ParseTerm("tooltip/Stamina/Weapon")
H.listEq("a keyword after a needle is NOT a second needle",
         needles(claimed), { "Stamina" })
H.eq("...it is parsed as the class it names", claimed.class, 1)

-- ...and the escape hatch it leaves behind.
H.listEq("repeating the keyword still says 'needle'",
         needles(buy.ParseTerm("tooltip/Stamina/tooltip/Weapon")),
         { "Stamina", "Weapon" })

-- WHAT COMES BACK OUT. The short form is emitted so the builder and the saved
-- search list hand back what was typed...
H.eq("a run-on is emitted short",
     buy.TermToQuery(buy.ParseTerm("wristbands/tooltip/+3 stam/+3 agi")),
     "wristbands/tooltip/+3 stam/+3 agi")
-- ...except where short would re-parse as something else, which is the whole
-- reason the emitter has to ask the same keyword question the parser does.
H.eq("a needle that reads as a keyword keeps its own tooltip/",
     buy.TermToQuery(buy.ParseTerm("tooltip/Stamina/tooltip/Weapon")),
     "tooltip/Stamina/tooltip/Weapon")
-- A combinator breaks the run, so the needle after it cannot go bare either --
-- "tooltip/A/or/B" would leave B as name text.
H.eq("a needle after a combinator keeps its own tooltip/",
     buy.TermToQuery(buy.ParseTerm("cloak/tooltip/a/or/tooltip/b")),
     "cloak/tooltip/a/or/tooltip/b")

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
    "cloak/tooltip/stamina/beastslaying",
    "cloak/tooltip/stamina/tooltip/weapon",
    "cloak/tooltip/a/or/tooltip/b",
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

-- ---------------------------------------------------------------------------
H.section("The `usable` flag reaches the client in a shape it understands")
-- ---------------------------------------------------------------------------

-- REPORTED BUG, v1.21.0 and earlier: ticking "Usable items" did nothing. The
-- term carried the flag correctly all the way to CompileTerm, which handed
-- QueryAuctionItems a Lua BOOLEAN. Legal Lua, query still sent, filter simply
-- never applied -- and every assertion in this file passed, because none of
-- them looked at that slot.
--
-- CompileTerm is checked directly as well as through a sent query: the value
-- is what matters, and reading it off the compiled term says so without
-- depending on the driver having ticked.
local plain = buy.CompileTerm(buy.ParseTerm("linen cloth"))
H.isNil("no usable flag means the arg is ABSENT, not 0",
        plain.blizz.isUsable)

local usable = buy.CompileTerm(buy.ParseTerm("linen cloth/usable"))
H.eq("a usable term sends 1", usable.blizz.isUsable, 1)
H.neq("...a number, not a boolean", type(usable.blizz.isUsable), "boolean")

-- 0 is the tempting spelling for "off" and it is WRONG: 0 is truthy in Lua,
-- so a client reading the slot as a flag would take it as "usable only" and
-- narrow every search. nil is the only safe off, and it is what CLAUDE.md
-- rule 9 requires of every index/flag arg.
H.neq("off is never 0", plain.blizz.isUsable, 0)

-- And through the real path, because tests/support/wow.lua asserts the shape
-- on the way in -- a wrong value fails the call itself.
W.queries = {}
W.queryOpen = true
buy.Search("linen cloth/usable")
W.TickUntil(buy.driver, function() return table.getn(W.queries) > 0 end, 50)
local uq = W.queries[1]
H.eq("the sent query carries isUsable = 1", uq and uq.isUsable, 1)

os.exit(H.report("buy.term"))
