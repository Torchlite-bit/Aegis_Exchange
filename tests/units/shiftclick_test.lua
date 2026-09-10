-- Aegis: Exchange -- tests/units/shiftclick_test.lua
--
-- Shift-click an item, and its name lands in a search box.
--
-- THE STOCK UI DOES THIS. Shift-click an item in your bags with the auction
-- house open and its name goes into the browse box. Our window REPLACES that
-- browse box, so without this the gesture stops working the moment a player
-- installs Aegis -- a thing taken away, which is worse than a thing never
-- offered.
--
-- The rule about WHERE it lands is two lists and a visibility test, so it is
-- extracted from ui/frame.lua and run here against stand-in boxes. Extracted,
-- not copied: a duplicate would drift.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

local function Source(path)
    local f = assert(io.open(path, "r"), "run this from the repo root")
    local s = f:read("*a")
    f:close()
    return s
end

local function extract(path, signature)
    local body, grabbing = {}, false
    for line in string.gfind(Source(path), "([^\n]*)\n") do
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
    "function ui.LinkTargetFor(",
    "function ui.ShiftClickIsOurs(",
}) do
    local fn, err = loadstring(extract("ui/frame.lua", sig), sig)
    if not fn then error(sig .. " will not compile: " .. tostring(err)) end
    fn()
end

-- The two client globals the predicate reads.
IsShiftKeyDown = function() return SHIFT end
ChatFrameEditBox = { shown = false }
ChatFrameEditBox.IsShown = function(self) return self.shown end

-- A stand-in edit box: it only has to say whether it is on screen and take a
-- name. That is the whole surface ui.LinkTargetFor touches.
local function Box(name, visible)
    local b = { name = name, shown = visible, text = "" }
    b.IsVisible = function(self) return self.shown end
    b.SetText   = function(self, t) self.text = t end
    b.GetText   = function(self) return self.text end
    return b
end

-- ---------------------------------------------------------------------------
H.section("which box a shift-clicked item lands in")
-- ---------------------------------------------------------------------------

local buy   = Box("buy",   true)
local query = Box("query", false)   -- Advanced mode; hidden in default mode
local craft = Box("craft", false)   -- another tab
local TARGETS = { buy, query, craft }

-- ONLY THE VISIBLE TAB'S BOXES ARE VISIBLE, which is why this needs no tab
-- name: the panels do the filtering by being hidden.
H.eq("with nothing focused it goes to the visible box",
     ui.LinkTargetFor(nil, TARGETS), buy)

buy.shown, craft.shown = false, true
H.eq("...and follows the visible tab", ui.LinkTargetFor(nil, TARGETS), craft)

-- FOCUS WINS. A player who has clicked into a box has said where they want the
-- name, and that beats "the first visible one" -- which, with the Buy tab's
-- two boxes registered ahead of the Crafting one, would otherwise be wrong
-- every time somebody clicked into a box further down the list.
buy.shown, craft.shown = true, true
H.eq("a focused box wins over the first visible one",
     ui.LinkTargetFor(craft, TARGETS), craft)
H.eq("...even though the other one is registered first",
     TARGETS[1], buy)

-- A box that is focused but not on screen cannot take it. Changing tabs
-- without clearing focus is enough to produce that state, and the name would
-- land somewhere nobody can see.
H.eq("a focused box that is hidden does not take it",
     ui.LinkTargetFor(Box("gone", false), TARGETS), buy)

-- Nothing on screen -- the window is shut. The caller falls through to the
-- client's own handler, so chat and the Blizzard AH still get the link.
buy.shown, query.shown, craft.shown = false, false, false
H.isNil("nothing visible takes nothing", ui.LinkTargetFor(nil, TARGETS))
H.isNil("...and an empty list too", ui.LinkTargetFor(nil, {}))
H.isNil("...and a nil list", ui.LinkTargetFor(nil, nil))

-- ---------------------------------------------------------------------------
H.section("which click is ours")
-- ---------------------------------------------------------------------------

-- READ OFF THE CLIENT'S OWN 1.12 SOURCE, not guessed. ContainerFrame.lua takes
-- its shift branch on button == "LeftButton", IsShiftKeyDown() and
-- not ignoreModifiers -- and inside it inserts to chat only when
-- ChatFrameEditBox is shown, otherwise opening the stack-split dialog. We slot
-- in exactly where that split dialog would go.
SHIFT = true
ChatFrameEditBox.shown = false

H.check("shift + LEFT click is ours", ui.ShiftClickIsOurs("LeftButton", nil),
        "the gesture the whole feature is named after was refused")

-- BLIZZARD'S DEFAULT IS SHIFT+LEFT. The first build hooked a function 1.12
-- does not have, so shift+left opened the stack-split dialog instead -- and
-- the right button must stay what it has always been.
H.check("shift + RIGHT click is NOT ours",
        not ui.ShiftClickIsOurs("RightButton", nil),
        "right-click was taken; on 1.12 that is the merchant sell path")

H.check("an unmodified left click is not ours",
        not (function() SHIFT = false
             local r = ui.ShiftClickIsOurs("LeftButton", nil)
             SHIFT = true; return r end)(),
        "picking an item up would stop working")

-- `ignoreModifiers` is the client re-entering its own handler to run the
-- unmodified path. Taking that would make one click do two things.
H.check("the client's own re-entry is not ours",
        not ui.ShiftClickIsOurs("LeftButton", 1),
        "the handler would fire twice for one click")

-- CHAT WINS. Composing a message and shift-clicking means "put it in the
-- message", everywhere else in the game.
ChatFrameEditBox.shown = true
H.check("...not while a chat message is being composed",
        not ui.ShiftClickIsOurs("LeftButton", nil),
        "a link would be stolen from a message the player is typing")
ChatFrameEditBox.shown = false

-- ---------------------------------------------------------------------------
H.section("the hook is a saved original, not a secure hook")
-- ---------------------------------------------------------------------------

-- HARD RULE 7: 1.12 has no secure-hook infrastructure. The pattern is save the
-- original and replace it, then call the saved one from the replacement --
-- which is also what keeps chat working when we decline the link.
--
-- The BAN on secure hooks is lua50.py's job and it is not repeated here: a
-- substring test for "hooksecurefunc" in this file matches the COMMENT next to
-- ui.HookAuctionFrame explaining why we do not use one, which is the checker
-- fooled by its own documentation that definitions.py was written about. What
-- IS this suite's job is that the saved original is kept and called.
local src = Source("ui/frame.lua")
-- CONTAINERFRAMEITEMBUTTON_ONCLICK is the function 1.12 actually calls.
-- The first build hooked ChatEdit_InsertLink, which stock 1.12 does not have
-- -- so nothing fired and shift+left opened the stack-split dialog. Naming the
-- right function here is what stops that being re-decided from memory.
H.check("the container click handler is the one hooked",
        string.find(src,
            "ui.origContainerClick = ContainerFrameItemButton_OnClick",
            1, true) ~= nil,
        "the function 1.12 calls on a bag click is not hooked")
H.check("...and its original is called whenever we decline",
        string.find(src,
            "return ui.origContainerClick(button, ignoreModifiers)",
            1, true) ~= nil,
        "picking up, splitting and Ctrl-dressing would stop working")

-- The replacement is on the click path for EVERY bag slot in the game,
-- including with our window shut, so an error in it would break picking items
-- up for the whole session.
H.check("our half runs under pcall",
        string.find(src,
            "local ok, took = pcall(ui.TakeContainerShiftClick, button, ignoreModifiers)",
            1, true) ~= nil,
        "an error in our code would break bag clicks for the session")

os.exit(H.report("shiftclick"))
