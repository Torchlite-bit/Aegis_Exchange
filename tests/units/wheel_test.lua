-- Aegis: Exchange -- tests/units/wheel_test.lua
--
-- The mouse wheel on numbers, and at the window's edge (issue #105).
--
-- Asked for as: "much easier than needing to drag a slider or change a number
-- when you want to change the price by 1 copper" -- and: "disable the
-- scrollbar when inside the whole user interface to make it safer in Booty
-- Bay for those that have scrollbar bound to attack".
--
-- What this pins:
--   * one notch is one step, TEN with Shift; a number stays inside its range;
--   * over a PRICE, the step is the coin under the pointer -- a copper, a
--     silver or a gold -- and it rolls over between them, never below nothing;
--   * a notch repaints whatever typing would: a number box through its own
--     OnTextChanged, a price through its change callback (its SetText is
--     quiet), a slider through OnValueChanged;
--   * the window and the shopping list take a wheel nothing inside took, so
--     it never reaches a key binding.
--
-- No suite loads ui/frame.lua; the builders are taken out of its source and
-- run here.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)

local f = assert(io.open("ui/frame.lua", "r"), "run this from the repo root")
local src = f:read("*a")
f:close()

-- From `head` to the end of the function it opens, `end` included.
local function chunk(head)
    local at = assert(string.find(src, head, 1, true), "did not find: " .. head)
    local stop = assert(string.find(src, "\nend\n", at, true))
    return string.sub(src, at, stop + 4)
end
local function has(body, needle) return string.find(body, needle, 1, true) ~= nil end

ui = {}
_G.A = A
util = A.util
local shiftHeld = false
IsShiftKeyDown = function() return shiftHeld end

-- The helpers: everything from the shift constant to ui.SwallowWheel.
do
    local at = assert(string.find(src, "ui.WHEEL_SHIFT = 10", 1, true))
    local stop = string.find(src, "\nend\n", string.find(src, "function ui.SwallowWheel(", at, true), true)
    assert(loadstring(string.sub(src, at, stop + 4)))()
end

-- Turn the wheel once over `frame`: the client sets arg1 and `this`, then
-- calls the script with no arguments.
local function notch(frame, delta, shift)
    shiftHeld = shift and true or false
    arg1, this = delta, frame
    frame.scripts.OnMouseWheel()
    shiftHeld = false
end

-- ---------------------------------------------------------------------------
H.section("One notch: one step, ten with Shift, inside the range")
-- ---------------------------------------------------------------------------

H.eq("up is one", ui.WheelStep(1, false), 1)
H.eq("down is minus one", ui.WheelStep(-1, false), -1)
H.eq("Shift makes it ten", ui.WheelStep(1, true), 10)
H.eq("...either way", ui.WheelStep(-1, true), -10)
H.eq("5 up is 6", ui.WheelNumber(5, 1, false, 1, nil), 6)
H.eq("1 down stays at the floor", ui.WheelNumber(1, -1, false, 1, nil), 1)
H.eq("18 up by ten stops at the ceiling", ui.WheelNumber(18, 1, true, 1, 20), 20)
H.eq("nothing up is one", ui.WheelNumber(nil, 1, false, nil, nil), 1)

-- A price, by the coin under the pointer.
H.eq("99c, a copper up, is 1s", ui.WheelMoney(99, 1, false, 1), 100)
H.eq("1s 50c, a silver up, is 2s 50c", ui.WheelMoney(150, 1, false, 100), 250)
H.eq("1g 2s, ten gold up with Shift, is 11g 2s",
     ui.WheelMoney(10200, 1, true, 10000), 110200)
H.eq("50c, a silver down, is nothing -- never below", ui.WheelMoney(50, -1, false, 100), 0)
H.eq("nothing, a copper up, is 1c", ui.WheelMoney(nil, 1, false, 1), 1)

-- ---------------------------------------------------------------------------
H.section("A number box")
-- ---------------------------------------------------------------------------

-- The harness's frames answer ANY missing key with a do-nothing function, so
-- an unset `wheelRange` would read as a range that returns nothing. A real
-- frame answers nil for a field nobody set. These frames invent METHODS only
-- (capitalised names) and leave fields nil, as the client does.
local realCreate = CreateFrame
local methodsOnly = {
    __index = function(t, k)
        if type(k) == "string" and string.find(k, "^%u") then
            local fn = function() end
            rawset(t, k, fn)
            return fn
        end
        return nil
    end,
}
local function clientFrame(kind)
    local fr = realCreate(kind)
    setmetatable(fr, methodsOnly)
    fr.CreateTexture = function() return realCreate("Texture") end
    return fr
end

-- A box whose SetText fires its own OnTextChanged, as the client's does.
local function textBox()
    local e = clientFrame("EditBox")
    e.SetText = function(self, t)
        self.text = t
        local h = self.scripts.OnTextChanged
        if h then this = self; h() end
    end
    return e
end
ui.FlattenEditBox = function(e) return e end
CreateFrame = function(kind, name, parent, template)
    if kind == "EditBox" then return textBox() end
    return clientFrame(kind)
end
local MakeNumBox = assert(loadstring(chunk("local function MakeNumBox(")
    .. "\nreturn MakeNumBox"))()

local typed = 0
local box = MakeNumBox(realCreate("Frame"), 34, function() typed = typed + 1 end)
H.check("every number box takes the wheel", box.scripts.OnMouseWheel ~= nil)
notch(box, 1)
H.eq("a blank box, one up, is its floor", box:GetText(), "1")
H.eq("...and repaints as typing would", typed, 1)
notch(box, 1, true)
H.eq("Shift: ten more", box:GetText(), "11")
notch(box, -1, true)
notch(box, -1, true)
H.eq("down past the floor stops at 1", box:GetText(), "1")
box.wheelRange = function() return 1, 12 end
box:SetText("10")
notch(box, 1, true)
H.eq("a range from the slider beside it holds the ceiling", box:GetText(), "12")

-- A box that commits only on Enter or focus lost commits on a notch.
local committed = false
local uc = textBox()
uc.wheelRange = function() return 1, 99 end
ui.WheelBox(uc, function() committed = true end)
uc:SetText("5")
notch(uc, 1)
H.eq("the undercut box moves", uc:GetText(), "6")
H.check("...and commits", committed)

-- ---------------------------------------------------------------------------
H.section("A price: the coin under the pointer")
-- ---------------------------------------------------------------------------

local MakeMoneyGSC = assert(loadstring("local MakeMoneyGSC\n"
    .. chunk("MakeMoneyGSC = function(parent, onChange)")
    .. "\nreturn MakeMoneyGSC"))()
local panel = realCreate("Frame")
panel.CreateTexture = function() return realCreate("Texture") end
local changes = 0
local price = MakeMoneyGSC(panel, function() changes = changes + 1 end)
price:SetText(util.FormatMoney(99, false))      -- 99c
H.check("each coin takes the wheel", price.c.scripts.OnMouseWheel ~= nil
        and price.s.scripts.OnMouseWheel ~= nil and price.g.scripts.OnMouseWheel ~= nil)
notch(price.c, 1)
H.eq("a copper up from 99c rolls into silver", price:Copper(), 100)
H.eq("...and the boxes show it", price.s:GetText() .. "s" .. price.c:GetText() .. "c", "1s0c")
H.eq("...announced like a keystroke", changes, 1)
notch(price.s, 1, true)
H.eq("ten silver up with Shift", price:Copper(), 1100)
notch(price.g, 1)
H.eq("a gold up", price:Copper(), 11100)
notch(price.g, -1, true)
H.eq("ten gold down from 1g 11s is nothing, not less", price:Copper(), 0)
H.eq("...and the boxes are empty again", price:GetText(), "")

-- ---------------------------------------------------------------------------
H.section("A slider")
-- ---------------------------------------------------------------------------

local MakeHSlider = assert(loadstring("local MakeHSlider\n"
    .. chunk("MakeHSlider = function(parent, width, onChange)")
    .. "\nreturn MakeHSlider"))()
local moved
local sb = MakeHSlider(realCreate("Frame"), 150, function(v) moved = v end)
sb.lo, sb.hi, sb.v = 1, 6, 3
sb.GetMinMaxValues = function(self) return self.lo, self.hi end
sb.GetValue = function(self) return self.v end
sb.SetValue = function(self, v)
    self.v = v
    this = self
    self.scripts.OnValueChanged()
end
notch(sb, 1)
H.eq("a notch moves the slider a step", sb.v, 4)
H.eq("...and the box beside it follows", moved, 4)
notch(sb, 1, true)
H.eq("ten with Shift stops at its end", sb.v, 6)

CreateFrame = realCreate

-- ---------------------------------------------------------------------------
H.section("The wheel stops at the window's edge")
-- ---------------------------------------------------------------------------

local win = realCreate("Frame")
ui.SwallowWheel(win)
H.check("the window takes the wheel", win.scripts.OnMouseWheel ~= nil)
notch(win, 1)
H.check("...and does nothing with it", true)
H.check("the main window swallows it",
        has(src, "    ui.ApplyRaiseGroup()\n"
            .. "    -- A wheel nothing inside took ends here, not at your key bindings\n"
            .. "    -- (issue #105). See ui.SwallowWheel.\n    ui.SwallowWheel(f)\n"))
H.check("...and so does the shopping list",
        has(src, "    ui.shopFrame = f\n    ui.SwallowWheel(f)"))

-- ---------------------------------------------------------------------------
H.section("Every number in the window is wired")
-- ---------------------------------------------------------------------------

H.check("the Sell tab's stack size keeps to its slider",
        has(src, "ui.sellStackSize.wheelRange = function()\n"
            .. "        return ui.sellSizeSlider:GetMinMaxValues()"))
H.check("...and the stack count to its",
        has(src, "ui.sellNumStacks.wheelRange = function()\n"
            .. "        return ui.sellCountSlider:GetMinMaxValues()"))
H.check("the level boxes keep to 1..60",
        has(src, "    ui.buyMinLevel.wheelRange = ui.LevelRange")
        and has(src, "    ui.buyMaxLevel.wheelRange = ui.LevelRange")
        and has(src, "    ui.fbMinLevel.wheelRange = ui.LevelRange")
        and has(src, "    ui.fbMaxLevel.wheelRange = ui.LevelRange"))
assert(loadstring(chunk("function ui.LevelRange(")))()
local llo, lhi = ui.LevelRange()
H.check("...which is 1 to 60", llo == 1 and lhi == 60)
H.check("Post All's auction limit keeps to the auction cap",
        has(src, "    cap.wheelRange = function() return 1, A.sell.CAP end"))
H.check("the undercut % box commits on a notch",
        has(src, "    ui.WheelBox(uc, function() ui.CommitUndercut() end)"))

os.exit(H.report("wheel"))
