-- Aegis: Exchange -- tests/units/taborder_test.lua
--
-- Tab traversal between input boxes: ui.NextInputIn decides where the cursor
-- goes, and ui.LinkTabOrder binds it.
--
-- WHY THE DECIDER IS TESTED AND THE BINDING IS NOT. SetScript, SetFocus and
-- HighlightText are frame API and need a client. Choosing the next box is
-- arithmetic over a list, and it has two ways to go wrong that a screenshot
-- would never show: wrapping off the front of the list (math.mod is fmod on
-- Lua 5.0 and returns a NEGATIVE remainder, which indexes nothing), and
-- landing on a box the current mode has hidden -- keystrokes then go
-- somewhere the eye cannot follow.
--
-- The function is extracted from ui/frame.lua at run time rather than copied.
-- Restating its arithmetic here would test the author, not the code; that
-- mistake has already let two bugs through in this repo.

package.path = "tests/support/?.lua;" .. package.path
local H = require("harness")

local SRC = "ui/frame.lua"

local function Source()
    local f = assert(io.open(SRC, "r"), "run this from the repo root")
    local s = f:read("*a")
    f:close()
    return s
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
do
    local fn, err = loadstring(extract("function ui.NextInputIn("),
                               "NextInputIn")
    if not fn then error("will not compile: " .. tostring(err)) end
    fn()
end

-- A stand-in for an edit box. The only thing NextInputIn asks of one is
-- whether it is on screen.
local function Box(name, visible)
    return {
        name = name,
        visible = (visible ~= false),
        IsVisible = function(self) return self.visible end,
    }
end

local function nameOf(box) return box and box.name or nil end

-- ---------------------------------------------------------------------------
H.section("Forwards, backwards, and round the end")
-- ---------------------------------------------------------------------------

local a, b, c = Box("a"), Box("b"), Box("c")
local list = { a, b, c }

H.eq("Tab moves to the next box", nameOf(ui.NextInputIn(list, a)), "b")
H.eq("...and the next again", nameOf(ui.NextInputIn(list, b)), "c")
H.eq("Tab off the end wraps to the first",
     nameOf(ui.NextInputIn(list, c)), "a")

H.eq("Shift-Tab moves back", nameOf(ui.NextInputIn(list, c, true)), "b")
H.eq("...and back again", nameOf(ui.NextInputIn(list, b, true)), "a")
-- THE fmod TRAP: at - 1 + step is -1 here, and a negative remainder would
-- index nothing at all.
H.eq("Shift-Tab off the FRONT wraps to the last",
     nameOf(ui.NextInputIn(list, a, true)), "c")

-- Never a no-op move: landing back on the box you started from would look
-- like Tab being ignored.
H.neq("the next box is never the current one",
      nameOf(ui.NextInputIn(list, b)), "b")

-- ---------------------------------------------------------------------------
H.section("Hidden boxes are stepped over")
-- ---------------------------------------------------------------------------

-- The case this exists for: the Sell tab's money triplets, the settings
-- panel's flat-amount boxes and the Buy tab's bid entry all come and go with
-- the mode they belong to.
b.visible = false
H.eq("a hidden box is skipped forwards", nameOf(ui.NextInputIn(list, a)), "c")
H.eq("...and backwards", nameOf(ui.NextInputIn(list, c, true)), "a")

local d, e = Box("d", false), Box("e")
local gappy = { a, b, d, e }        -- b and d both hidden
H.eq("a RUN of hidden boxes is skipped, not just one",
     nameOf(ui.NextInputIn(gappy, a)), "e")
H.eq("...and backwards over the same run",
     nameOf(ui.NextInputIn(gappy, e, true)), "a")

b.visible = true

-- ---------------------------------------------------------------------------
H.section("Dead ends return nil, and nil means STAY")
-- ---------------------------------------------------------------------------

-- The caller reads nil as "do not move". It must never be read as "clear
-- focus": losing the cursor is a worse answer than not moving it.
local lone = Box("lone")
H.isNil("a list of one has nowhere to go", ui.NextInputIn({ lone }, lone))

local hidden = { a, Box("x", false), Box("y", false) }
H.isNil("nothing visible to move to", ui.NextInputIn(hidden, a))

H.isNil("a box that is not in the list", ui.NextInputIn(list, Box("stranger")))
H.isNil("an empty list", ui.NextInputIn({}, a))
H.isNil("no list at all", ui.NextInputIn(nil, a))

-- ---------------------------------------------------------------------------
H.section("The autocomplete exception is real, in the source")
-- ---------------------------------------------------------------------------

-- Tab autocompletes item names on the two search boxes and traverses
-- everywhere else. That is a DECISION, not an oversight, and the only way it
-- can be broken is by someone adding one of those boxes to a traversal chain
-- -- at which point autocomplete silently stops working and nothing else
-- notices. So the chains are read out of the file and checked.
local src = Source()

local chains, n = {}, 0
for body in string.gfind(src, "ui%.LinkTabOrder%(%b{}%)") do
    n = n + 1
    table.insert(chains, body)
end
H.check("the traversal chains are wired up at all", n >= 5, "found " .. n)

local trespass = nil
for i = 1, n do
    if string.find(chains[i], "ui.buyBox", 1, true)
        or string.find(chains[i], "ui.buyQueryBox", 1, true) then
        trespass = chains[i]
    end
end
H.isNil("no search box was added to a traversal chain", trespass)

-- And the binding they keep instead.
local _, autocompletes = string.gsub(src,
    'SetScript%("OnTabPressed", function%(%) ui%.BuyAutocomplete%(%) end%)', "")
H.eq("both search boxes still autocomplete on Tab", autocompletes, 2)

os.exit(H.report("taborder"))
