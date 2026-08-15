-- Aegis: Exchange -- tests/units/builder_term_test.lua
--
-- The Filter Builder's form <-> term round trip, for the three options the
-- form gained in 1.19.0: Buyout only, Full stacks only, and Stack Size.
--
-- WHY THIS EXISTS. buy.ParseTerm and buy.TermToQuery have always understood
-- `buyout`, bare `stack` and `stack/N`. ui.BuilderTerm did not read any of
-- them, so a query carrying one lost it the moment you pressed Build --
-- silently, because the rest of the term rebuilt correctly and nothing said a
-- flag had gone. This pins both directions.
--
-- ui/frame.lua cannot be loaded here (it needs a real frame API), so the two
-- functions under test are extracted from the source at run time and run
-- against stand-in controls. Extracted, not copied: a duplicate would drift.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
-- GLOBAL, not local: the extracted chunks reach for `A` the way ui/frame.lua's
-- file-scope local does, and a local here would not be visible to them.
A = W.LoadCore()
W.FireAddonLoaded(A)

-- ---------------------------------------------------------------------------
-- Pull the two functions out of ui/frame.lua
-- ---------------------------------------------------------------------------

local function extract(path, signature)
    local f = io.open(path, "r")
    if not f then
        error("cannot open " .. path .. " -- run this from the repo root")
    end
    local body, grabbing = {}, false
    for line in f:lines() do
        if not grabbing then
            if string.find(line, signature, 1, true) == 1 then
                grabbing = true
                table.insert(body, line)
            end
        else
            table.insert(body, line)
            if line == "end" then break end     -- top-level end, column 1
        end
    end
    f:close()
    if not grabbing then error("did not find: " .. signature) end
    return table.concat(body, "\n")
end

-- The extracted chunks reference the file-scope locals ui/frame.lua gives
-- them: `ui`, `util`, and `A` (the addon namespace, for A.buy.*). As globals
-- here, they resolve the same way.
ui = {}
util = A.util
BuilderQualityOptions = function() return {} end

-- A stand-in for the form's controls. Only the methods the two functions
-- actually call: text boxes answer Get/SetText, checkboxes Get/SetChecked,
-- dropdowns GetValue/SetValue/SetOptions.
local function box(text)
    local b = { text = text or "" }
    b.GetText = function(self) return self.text end
    b.SetText = function(self, t) self.text = t or "" end
    return b
end
local function tick(on)
    local c = { on = on and true or false }
    c.GetChecked = function(self) if self.on then return 1 end return nil end
    c.SetChecked = function(self, v) self.on = v and true or false end
    return c
end
local function drop(v)
    local d = { value = v }
    d.GetValue = function(self) return self.value end
    d.SetValue = function(self, x) self.value = x end
    d.SetOptions = function() end
    return d
end

local function newForm()
    ui.fbName      = box("")
    ui.fbExact     = tick(false)
    ui.fbUsable    = tick(false)
    ui.fbBuyout    = tick(false)
    ui.fbFullStack = tick(false)
    ui.fbStackSize = box("")
    ui.fbMinLevel  = box("")
    ui.fbMaxLevel  = box("")
    ui.fbClass     = drop(nil)
    ui.fbSubclass  = drop(nil)
    ui.fbSlot      = drop(nil)
    ui.fbQuality   = drop(nil)
    ui.builderPost = {}
    ui.RefreshBuilder = function() end
end

for _, sig in ipairs({
    "function ui.BuilderTerm(",
    "function ui.BuilderSetTerm(",
    "function ui.BuilderStackGate(",
}) do
    local chunk = extract("ui/frame.lua", sig)
    local fn, err = loadstring(chunk, sig)
    if not fn then error(sig .. " will not compile: " .. tostring(err)) end
    fn()
end

-- BuilderSetTerm calls A.buy.* for the dropdown options; the stand-in
-- dropdowns ignore them, but the calls still have to resolve.
local buy = A.buy

-- ---------------------------------------------------------------------------
H.section("BuilderTerm reads the three options")
-- ---------------------------------------------------------------------------

newForm()
ui.fbBuyout:SetChecked(1)
local t = ui.BuilderTerm()
H.eq("Buyout only reaches the term", t.buyoutOnly, true)
H.eq("...and emits `buyout`", buy.TermToQuery(t), "buyout")

newForm()
ui.fbFullStack:SetChecked(1)
t = ui.BuilderTerm()
H.eq("Full stacks reaches the term", t.stackOnly, true)
H.eq("...and emits bare `stack`", buy.TermToQuery(t), "stack")

newForm()
ui.fbStackSize:SetText("20")
t = ui.BuilderTerm()
H.eq("Stack Size reaches the term", t.stackSize, 20)
H.eq("...and emits `stack/20`", buy.TermToQuery(t), "stack/20")

-- Before this change ALL THREE of the above came back nil and every query
-- above was the empty string. That is the bug, stated as a test.
newForm()
t = ui.BuilderTerm()
H.eq("an untouched form sets no buyout flag", t.buyoutOnly, false)
H.eq("...no stack flag", t.stackOnly, false)
H.isNil("...and no stack size", t.stackSize)

-- ---------------------------------------------------------------------------
H.section("Full stacks and an explicit size are mutually exclusive")
-- ---------------------------------------------------------------------------

-- The term cannot hold both: TermToQuery emits `stack/N` when stackSize is
-- set and bare `stack` only when it is not. A form that let you set both
-- would express a state the query language has no spelling for, and Build
-- would silently drop one.

-- The gate: typing a size clears the tick.
newForm()
ui.fbFullStack:SetChecked(1)
ui.fbStackSize:SetText("12")
ui.BuilderStackGate()
H.eq("typing a size unticks Full stacks", ui.fbFullStack:GetChecked(), nil)

-- Clearing the size leaves the tick alone -- the gate only fires on a real
-- number, or clearing the box would fight the user re-ticking the box.
newForm()
ui.fbFullStack:SetChecked(1)
ui.fbStackSize:SetText("")
ui.BuilderStackGate()
H.eq("clearing the size does NOT untick Full stacks",
     ui.fbFullStack:GetChecked(), 1)

-- A size of 0 is not a size.
newForm()
ui.fbFullStack:SetChecked(1)
ui.fbStackSize:SetText("0")
ui.BuilderStackGate()
H.eq("a zero size does not untick Full stacks",
     ui.fbFullStack:GetChecked(), 1)

-- And BuilderTerm enforces it again, so even a form set directly past the
-- gate cannot produce a term holding both.
newForm()
ui.fbFullStack:SetChecked(1)
ui.fbStackSize:SetText("20")
t = ui.BuilderTerm()
H.eq("an explicit size wins over the tick", t.stackSize, 20)
H.eq("...and the tick is dropped, not carried alongside", t.stackOnly, false)
H.eq("...so the query names the size only", buy.TermToQuery(t), "stack/20")

-- ---------------------------------------------------------------------------
H.section("BuilderSetTerm writes the three options back")
-- ---------------------------------------------------------------------------

newForm()
ui.BuilderSetTerm(buy.ParseTerm("linen/buyout"))
H.eq("`buyout` ticks Buyout only", ui.fbBuyout:GetChecked(), 1)

newForm()
ui.BuilderSetTerm(buy.ParseTerm("linen/stack"))
H.eq("bare `stack` ticks Full stacks", ui.fbFullStack:GetChecked(), 1)
H.eq("...and leaves the size box empty", ui.fbStackSize:GetText(), "")

newForm()
ui.BuilderSetTerm(buy.ParseTerm("linen/stack/20"))
H.eq("`stack/20` fills the size box", ui.fbStackSize:GetText(), "20")
H.eq("...and does NOT tick Full stacks", ui.fbFullStack:GetChecked(), nil)

-- A term holding BOTH. ParseTerm never builds one -- `stack/20` consumes its
-- number and leaves stackOnly false -- so this arrives by the other door: a
-- term assembled by hand, restored from an older saved search, or handed in
-- by a caller that set the fields directly. The form still must not end up
-- showing a state the query language cannot spell, so the size wins here too.
newForm()
ui.BuilderSetTerm({ name = "linen", stackOnly = true, stackSize = 20 })
H.eq("a term with both: the size is shown", ui.fbStackSize:GetText(), "20")
H.eq("...and Full stacks is NOT ticked alongside it",
     ui.fbFullStack:GetChecked(), nil)

-- ---------------------------------------------------------------------------
H.section("Full round trip: query -> form -> query")
-- ---------------------------------------------------------------------------

-- This is the failure the user actually hits: import a query, press Build,
-- and get back something narrower than what went in.
local cases = {
    "linen/buyout",
    "linen/stack",
    "linen/stack/20",
    "linen/exact/buyout",
    "linen/buyout/stack/20",
    "linen/usable/buyout/stack",
    "linen/quality/3/buyout/stack/12",
}
for i = 1, table.getn(cases) do
    newForm()
    local original = buy.ParseTerm(cases[i])
    ui.BuilderSetTerm(original)
    local rebuilt = ui.BuilderTerm()
    H.check("survives form -> Build: " .. cases[i],
            buy.TermsEqual(original, rebuilt),
            cases[i] .. "  ->  " .. buy.TermToQuery(rebuilt))
end

-- TermsEqual must be able to say no, or every check above is vacuous.
newForm()
ui.BuilderSetTerm(buy.ParseTerm("linen/buyout"))
ui.fbBuyout:SetChecked(nil)
H.check("dropping the flag IS detected",
        not buy.TermsEqual(buy.ParseTerm("linen/buyout"), ui.BuilderTerm()),
        "a lost buyout flag compared equal")

os.exit(H.report("builder.term"))
