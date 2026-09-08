-- Aegis: Exchange -- tests/units/window_point_test.lua
--
-- ui.PointIsReachable: can the window still be dragged from where it was left?
--
-- WHY THIS ONE IS TESTED AND THE REST OF THE POSITION CODE IS NOT. Saving and
-- restoring a point is frame API and needs a client. Deciding whether a saved
-- point is USABLE is arithmetic, and it is the only part that can strand a
-- user: the title bar is the window's only drag handle, so a point restored
-- off-screen -- saved on a large monitor, restored on a smaller one -- leaves
-- no way back short of wiping the saved variables.
--
-- The function is extracted from ui/frame.lua at run time rather than copied.

package.path = "tests/support/?.lua;" .. package.path
local H = require("harness")

local SRC = "ui/frame.lua"

local function extract(signature)
    local f = assert(io.open(SRC, "r"), "run this from the repo root")
    local body, grabbing = {}, false
    for line in f:lines() do
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
    f:close()
    if not grabbing then error("did not find: " .. signature) end
    return table.concat(body, "\n")
end

ui = {}
-- GRAB_MARGIN is a file-scope local the function reads.
BAR_H = (function()
    local f = assert(io.open(SRC, "r"))
    local v
    for line in f:lines() do
        local _, _, n = string.find(line, "^local BAR_H = (%d+)")
        if n then v = tonumber(n); break end
    end
    f:close()
    return assert(v, "did not find BAR_H")
end)()
GRAB_MARGIN = (function()
    local f = assert(io.open(SRC, "r"))
    local v
    for line in f:lines() do
        local _, _, n = string.find(line, "^local GRAB_MARGIN = (%d+)")
        if n then v = tonumber(n); break end
    end
    f:close()
    return assert(v, "did not find GRAB_MARGIN")
end)()

do
    local fn, err = loadstring(extract("function ui.PointIsReachable("),
                               "PointIsReachable")
    if not fn then error("will not compile: " .. tostring(err)) end
    fn()
end

local SW, SH = 1920, 1080      -- a screen
local WINW, WINH = 1200, 700   -- a window

local function ok(point, rel, x, y, sw, sh)
    return ui.PointIsReachable(point, rel, x, y, sw or SW, sh or SH,
                               WINW, WINH)
end

-- ---------------------------------------------------------------------------
H.section("Ordinary positions are reachable")
-- ---------------------------------------------------------------------------

H.check("centred", ok("CENTER", "CENTER", 0, 0), "")
H.check("nudged off centre", ok("CENTER", "CENTER", 120, -80), "")
H.check("anchored top-left at the origin", ok("TOPLEFT", "TOPLEFT", 0, 0), "")
H.check("anchored top-left, inset", ok("TOPLEFT", "TOPLEFT", 60, -40), "")
H.check("anchored bottom-right", ok("BOTTOMRIGHT", "BOTTOMRIGHT", -20, 20), "")

-- Deliberately hanging off an edge is allowed: someone who likes their window
-- half off the side keeps it. Only UNREACHABLE is refused.
H.check("half off the right edge is still fine",
        ok("TOPLEFT", "TOPLEFT", SW - 600, -100), "")
H.check("half off the left edge is still fine",
        ok("TOPLEFT", "TOPLEFT", -600, -100), "")

-- ---------------------------------------------------------------------------
H.section("Positions that would strand the window are refused")
-- ---------------------------------------------------------------------------

-- THE CASE THIS EXISTS FOR: saved on a wide screen, restored on a narrow one.
H.check("saved past the right edge of a smaller screen",
        not ui.PointIsReachable("TOPLEFT", "TOPLEFT", 1800, -100,
                                1024, 768, WINW, WINH),
        "1800 across a 1024 screen")
H.check("saved so far left only a sliver shows",
        not ok("TOPLEFT", "TOPLEFT", -(WINW - 40), -100), "")
H.check("dragged above the top edge",
        not ok("TOPLEFT", "TOPLEFT", 100, 40), "")
H.check("dragged below the bottom edge",
        not ok("TOPLEFT", "TOPLEFT", 100, -(SH + 10)), "")

-- Exactly GRAB_MARGIN of bar showing is the boundary, and it counts as
-- reachable -- the check refuses LESS than a grabbable slice, not exactly one.
H.check("exactly a grab margin on screen is reachable",
        ok("TOPLEFT", "TOPLEFT", SW - GRAB_MARGIN, -100),
        "at " .. (SW - GRAB_MARGIN))
H.check("one pixel less is not",
        not ok("TOPLEFT", "TOPLEFT", SW - GRAB_MARGIN + 1, -100),
        "at " .. (SW - GRAB_MARGIN + 1))

-- ---------------------------------------------------------------------------
H.section("Refuses to judge what it cannot measure")
-- ---------------------------------------------------------------------------

-- A screen size of 0 means UIParent has not been measured yet. Refusing the
-- saved point there would move every window to CENTER on some logins, which is
-- worse than the fault being guarded against.
H.check("an unmeasured screen keeps the saved point",
        ui.PointIsReachable("TOPLEFT", "TOPLEFT", 5000, -5000, 0, 0,
                            WINW, WINH),
        "should pass through when the screen is unknown")

-- A saved point with no anchor is not a point.
H.check("a nil point is refused",
        not ui.PointIsReachable(nil, "TOPLEFT", 0, 0, SW, SH,
                                WINW, WINH), "")
H.check("a nil relative point is refused",
        not ui.PointIsReachable("TOPLEFT", nil, 0, 0, SW, SH,
                                WINW, WINH), "")

-- ---------------------------------------------------------------------------
H.section("Every anchor is understood, not just TOPLEFT")
-- ---------------------------------------------------------------------------

-- The offsets mean different things per anchor, and getting one wrong sends
-- the window to CENTER for someone whose window was perfectly fine.
H.check("BOTTOMLEFT at the origin is reachable",
        ok("BOTTOMLEFT", "BOTTOMLEFT", 0, 0), "")
H.check("TOPRIGHT at the origin is reachable",
        ok("TOPRIGHT", "TOPRIGHT", 0, 0), "")
H.check("RIGHT at the origin is reachable", ok("RIGHT", "RIGHT", 0, 0), "")
H.check("LEFT at the origin is reachable", ok("LEFT", "LEFT", 0, 0), "")

-- ...and each one can still be pushed out of reach.
H.check("BOTTOMLEFT can be pushed off the left",
        not ok("BOTTOMLEFT", "BOTTOMLEFT", -(WINW - 40), 0), "")
H.check("TOPRIGHT can be pushed off the right",
        not ok("TOPRIGHT", "TOPRIGHT", WINW, -100), "")

-- ---------------------------------------------------------------------------
H.section("a dragged window is pulled back inside its own range")
-- ---------------------------------------------------------------------------

-- SetMinResize / SetMaxResize are asked for and DO NOT HOLD on this client: a
-- window dragged to ~1467 was reported, 67px past MAX_W. That matters because
-- every width-derived layout in the addon -- the whole Crafting tab -- is
-- written and asserted for MIN_W..MAX_W. Outside it, none of the guarantees
-- the geometry suite proves apply.
local src
do
    local f = assert(io.open("ui/frame.lua", "r"), "run this from the repo root")
    src = f:read("*a")
    f:close()
end

-- The CALL, not the definition. Searching for "ui.ApplyClampedSize()" plainly
-- matches "function ui.ApplyClampedSize()" as well, so deleting the call left
-- this green -- the checker satisfied by the thing it was checking for the
-- existence of. The leading indent is what distinguishes a call site here.
H.check("the resize grip clamps what the drag produced",
        string.find(src, "\n        ui.ApplyClampedSize()", 1, true) ~= nil,
        "a drag past MAX_W is laid out and saved as-is")

-- ...and it clamps BEFORE saving and before laying anything out against it.
local atClamp = string.find(src, "\n        ui.ApplyClampedSize()", 1, true)
H.check("...before the size is saved",
        atClamp < string.find(src, "ui.SaveWindowSize()", atClamp, true),
        "an out-of-range size is written to SavedVariables")
H.check("...and before the layout is run against it",
        atClamp < string.find(src, "ui.LayoutAll()", atClamp, true),
        "the layout runs at a width its own assertions do not cover")

-- ...and the clamp actually RESIZES. A grip handler that calls a function
-- which measures the window and then does nothing with the answer is the same
-- bug with an extra step.
-- ui.ApplyClampedSize reads the four bounds and ui.ClampWindowSize.
MIN_W, MIN_H = 1000, 492
MAX_W, MAX_H = 1400, 900
do
    local fn = assert(loadstring(extract("function ui.ClampWindowSize("),
                                 "ClampWindowSize"))
    fn()
    fn = assert(loadstring(extract("function ui.ApplyClampedSize("),
                           "ApplyClampedSize"))
    fn()
end

local function StubWindow(w, h)
    local f = { w = w, h = h }
    f.GetWidth  = function(self) return self.w end
    f.GetHeight = function(self) return self.h end
    f.SetWidth  = function(self, v) self.w = v end
    f.SetHeight = function(self, v) self.h = v end
    return f
end

ui.frame = StubWindow(MAX_W + 300, MAX_H + 300)
ui.ApplyClampedSize()
H.eq("a window dragged past the maximum is pulled back", ui.frame.w, MAX_W)
H.eq("...in both directions", ui.frame.h, MAX_H)

ui.frame = StubWindow(MIN_W - 200, MIN_H - 200)
ui.ApplyClampedSize()
H.eq("...and one dragged below the minimum is pushed out", ui.frame.w, MIN_W)
H.eq("...in both directions too", ui.frame.h, MIN_H)

-- A window already in range is left ALONE. Setting the size unconditionally
-- would fight anything else that has a say in it.
ui.frame = StubWindow(1200, 700)
ui.ApplyClampedSize()
H.eq("a window inside the range is untouched", ui.frame.w, 1200)
H.eq("...in both directions", ui.frame.h, 700)
ui.frame = nil

os.exit(H.report("window.point"))
