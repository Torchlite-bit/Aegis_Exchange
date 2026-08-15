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

os.exit(H.report("window.point"))
