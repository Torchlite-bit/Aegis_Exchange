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
do
    local fn, err = loadstring(extract("ui/frame.lua",
                                       "function ui.LinkTargetFor("),
                               "LinkTargetFor")
    if not fn then error("will not compile: " .. tostring(err)) end
    fn()
end

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
H.check("the original ChatEdit_InsertLink is saved",
        string.find(src, "ui.origInsertLink = ChatEdit_InsertLink", 1, true) ~= nil,
        "the client's function is not kept")
H.check("...and called when we decline the link",
        string.find(src, "return ui.origInsertLink(text)", 1, true) ~= nil,
        "declining the link drops it instead of passing it on")

-- CHAT WINS over our boxes. Shift-clicking while typing a message means "put
-- it in the message" everywhere else in the game; taking it would be a
-- surprise, not a feature.
H.check("the chat edit box is checked first",
        string.find(src,
            "if ChatFrameEditBox and ChatFrameEditBox:IsVisible() then return false end",
            1, true) ~= nil,
        "a link would be stolen from a message the player is typing")

-- The replacement runs on EVERY shift-click in the game, including with our
-- window shut, so an error in it would break linking into chat for the whole
-- session.
H.check("our half runs under pcall",
        string.find(src, "local ok, took = pcall(ui.InsertItemLink, text)",
                    1, true) ~= nil,
        "an error in our code would break chat linking for the session")

os.exit(H.report("shiftclick"))
