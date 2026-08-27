-- Aegis: Exchange -- tests/units/external_buttons_test.lua
--
-- The four buttons Aegis puts on somebody else's window: "Add to Aegis" on
-- the two profession frames, "Aegis: sell N marked" on the merchant, and
-- "Aegis UI" on the stock auction house.
--
-- WHY THESE ARE A CATEGORY. Every other Aegis button sits on the Aegis
-- window, where a dark flat plate is what everything around it looks like.
-- These four sit on gold parchment, and there the same plate reads as
-- something broken. They are stock UIPanelButtonTemplate buttons for that
-- reason, which also hands the pfUI case to pfUI's own SkinButton -- the
-- thing it is written for.
--
-- What is testable here is the ARITHMETIC and the RECORD, not the look:
-- whether a placement survives being nudged, and whether the nudge is applied
-- once, in the right direction, and only to buttons it knows. Whether the
-- result is actually clear of the Create row needs a client and a person.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.LoadUI("skin")
W.FireAddonLoaded(A)
local skin = A.skin

local CRAFT    = "AegisExchangeAddTradeSkillButton"
local CRAFT2   = "AegisExchangeAddCraftButton"
local MERCHANT = "AegisExchangeMerchantSellButton"
local SWAP     = "AegisExchangeSwapButton"

-- ---------------------------------------------------------------------------
H.section("every external button is named in the nudge table")
-- ---------------------------------------------------------------------------

-- Not decoration. A button missing from the table is not an error -- it just
-- silently keeps the stock placement in pfUI, which is the failure being
-- reported here in the first place.
local names = { CRAFT, CRAFT2, MERCHANT, SWAP }
local i = 1
while i <= table.getn(names) do
    H.check(names[i] .. " has an entry",
            skin.EXTERNAL_NUDGE[names[i]] ~= nil)
    i = i + 1
end

-- ---------------------------------------------------------------------------
H.section("skin.NudgedPoint")
-- ---------------------------------------------------------------------------

-- The reported faults, in the direction they were reported. "Add to Aegis"
-- sat flush against the panel's bottom-right inner border in pfUI, so it goes
-- UP; on this anchor (BOTTOMRIGHT to the Exit button's TOPRIGHT) up is +y.
local x, y = skin.NudgedPoint(CRAFT, -10, 8)
H.eq("the craft button does not move sideways", x, -10)
H.check("...and moves UP", y > 8, "got " .. y)

local cx, cy = skin.NudgedPoint(CRAFT, -10, 8)
x, y = skin.NudgedPoint(CRAFT2, -10, 8)
H.eq("both profession windows get the same treatment (x)", x, cx)
H.eq("...and the same treatment (y)", y, cy)

-- The merchant button rode high and tight against the tabs: right, and down.
x, y = skin.NudgedPoint(MERCHANT, 2, 0)
H.check("the merchant button moves RIGHT", x > 2, "got " .. x)
H.check("...and DOWN", y < 0, "got " .. y)

-- The stock AH button lands right in both, so it must not be moved at all.
x, y = skin.NudgedPoint(SWAP, -6, 0)
H.eq("the AH swap button keeps its x", x, -6)
H.eq("...and its y", y, 0)

-- A name the table has never heard of keeps exactly what the attach code gave
-- it. That is the safe direction: an unknown button is left where it was
-- rather than shoved somewhere arbitrary.
x, y = skin.NudgedPoint("AegisExchangeSomethingNew", 12, -3)
H.eq("an unknown button is not moved (x)", x, 12)
H.eq("an unknown button is not moved (y)", y, -3)

-- Missing offsets are zero, not nil arithmetic.
x, y = skin.NudgedPoint(MERCHANT, nil, nil)
H.eq("a nil x is treated as zero", x, skin.EXTERNAL_NUDGE[MERCHANT].x)
H.eq("a nil y is treated as zero", y, skin.EXTERNAL_NUDGE[MERCHANT].y)

-- ---------------------------------------------------------------------------
H.section("ui.SetExternalPoint records what it placed")
-- ---------------------------------------------------------------------------

-- The record is the whole mechanism: pfUI's nudge is applied by re-pointing
-- from it, so a placement the skin cannot see is one the skin silently fails
-- to adjust. That failure looks exactly like "the offset is wrong".
--
-- ui/frame.lua cannot be loaded here (it builds a window), so the function is
-- extracted from the source at run time -- never copied, or the test goes on
-- passing against code nobody runs.
local function extract(path, signature)
    local src = io.open(path):read("*a")
    local from = string.find(src, signature, 1, true)
    if not from then error("not found in " .. path .. ": " .. signature) end
    local _, stop = string.find(src, "\nend", from, true)
    return string.sub(src, from, stop)
end

ui = { }
local chunk = extract("ui/frame.lua", "function ui.SetExternalPoint(")
assert(loadstring(chunk))()

-- A stand-in for a button: records the points it is given.
local function FakeButton()
    local b = { points = {} }
    function b:ClearAllPoints() self.points = {} end
    function b:SetPoint(p, rel, relP, x, y)
        table.insert(self.points, { p = p, rel = rel, relP = relP, x = x, y = y })
    end
    return b
end

local anchor = { name = "MerchantFrameTab2" }
local btn = FakeButton()
ui.SetExternalPoint(btn, "LEFT", anchor, "RIGHT", 2, 0)

H.eq("it placed the button", table.getn(btn.points), 1)
H.eq("...at the point it was given", btn.points[1].p, "LEFT")
H.eq("...relative to the anchor", btn.points[1].rel, anchor)
H.check("it recorded the anchor", btn.aegisAnchor ~= nil)
H.eq("...the point", btn.aegisAnchor.point, "LEFT")
H.eq("...the frame", btn.aegisAnchor.rel, anchor)
H.eq("...the relative point", btn.aegisAnchor.relPoint, "RIGHT")
H.eq("...and BOTH offsets", btn.aegisAnchor.x, 2)
H.eq("...", btn.aegisAnchor.y, 0)

-- Nil offsets are stored as zero, so the nudge arithmetic downstream never
-- meets a nil.
local b2 = FakeButton()
ui.SetExternalPoint(b2, "TOPRIGHT", anchor, "TOPRIGHT")
H.eq("a missing x is recorded as zero", b2.aegisAnchor.x, 0)
H.eq("a missing y is recorded as zero", b2.aegisAnchor.y, 0)

-- No anchor frame, no placement and no record -- rather than a point against
-- nil, which is an error on the real client.
local b3 = FakeButton()
ui.SetExternalPoint(b3, "LEFT", nil, "RIGHT", 2, 0)
H.eq("a nil anchor places nothing", table.getn(b3.points), 0)
H.isNil("...and records nothing", b3.aegisAnchor)

-- ---------------------------------------------------------------------------
H.section("the record and the nudge compose")
-- ---------------------------------------------------------------------------

-- End to end, without pfUI: place a merchant button the way the attach code
-- does, then work out where the skin would move it.
local m = FakeButton()
ui.SetExternalPoint(m, "LEFT", anchor, "RIGHT", 2, 0)
local nx, ny = skin.NudgedPoint(MERCHANT, m.aegisAnchor.x, m.aegisAnchor.y)
H.check("the nudged x is right of where it started", nx > m.aegisAnchor.x)
H.check("the nudged y is below where it started", ny < m.aegisAnchor.y)

-- And the stock UI is the un-nudged case, which is the one that must not
-- regress: nothing in skin.lua runs unless pfUI is present.
H.eq("without the skin the button stays where it was placed",
     m.points[1].x, 2)
H.eq("...", m.points[1].y, 0)

-- ---------------------------------------------------------------------------
H.section("skin.NudgeExternal moves a button ONCE")
-- ---------------------------------------------------------------------------

-- The once-only guard is the part that cannot fail visibly. skin.ApplyExternal
-- runs on every attach AND from skin.Apply, so a nudge that re-applied would
-- walk the button a little further each time the merchant was opened -- and
-- the first open would look perfect.
local n1 = FakeButton()
ui.SetExternalPoint(n1, "LEFT", anchor, "RIGHT", 2, 0)
H.check("the first call moves it", skin.NudgeExternal(n1, MERCHANT))
H.eq("...by re-pointing, so exactly one point is live",
     table.getn(n1.points), 1)
local movedX, movedY = n1.points[1].x, n1.points[1].y
H.eq("...to the nudged x", movedX, skin.NudgedPoint(MERCHANT, 2, 0))

H.eq("a second call does nothing", skin.NudgeExternal(n1, MERCHANT), false)
H.eq("...and the button has not drifted (x)", n1.points[1].x, movedX)
H.eq("...and the button has not drifted (y)", n1.points[1].y, movedY)
-- Ten more, because "walks a little further each time" is the failure.
local k = 1
while k <= 10 do skin.NudgeExternal(n1, MERCHANT); k = k + 1 end
H.eq("ten more calls do not move it either", n1.points[1].x, movedX)

-- A zero nudge is still marked done, and still leaves the placement alone.
local z = FakeButton()
ui.SetExternalPoint(z, "RIGHT", anchor, "LEFT", -6, 0)
H.eq("a zero-nudge button reports no move",
     skin.NudgeExternal(z, SWAP), false)
H.eq("...and keeps the placement it was given", z.points[1].x, -6)

-- No record, no re-point. This is the state a button is in if something
-- placed it without going through ui.SetExternalPoint.
local bare = FakeButton()
bare:SetPoint("LEFT", anchor, "RIGHT", 2, 0)
H.eq("a button with no anchor record is left alone",
     skin.NudgeExternal(bare, MERCHANT), false)
H.eq("...and still has its original point", table.getn(bare.points), 1)

H.eq("nil is handled rather than erroring",
     skin.NudgeExternal(nil, MERCHANT), false)

os.exit(H.report("external.buttons"))
