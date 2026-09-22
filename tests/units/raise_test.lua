-- Aegis: Exchange -- tests/units/raise_test.lua
--
-- Window ordering: whatever you clicked last is in front.
--
-- WHAT WAS REPORTED. Opening the auction house opens your BACKPACK -- the
-- client does that itself -- and the bag landed behind the Aegis window with
-- no way to bring it forward. Clicking the bag did nothing; clicking ours put
-- ours back on top, which is the half that always worked.
--
-- WHAT HAS A WRONG ANSWER THAT STILL LOOKS RIGHT:
--
--   * PICKING A BETTER NUMBER. Any fixed z-order is wrong half the time. The
--     right answer is "the one you just clicked", and the client already
--     implements it -- SetToplevel(true). Our window had it and nothing else
--     in the argument did.
--   * TOPLEVEL ALONE. It only reorders WITHIN a strata, so a frame a whole
--     strata below can be clicked all day and never come forward. Setting the
--     flag and stopping there looks like a fix and changes nothing.
--   * LOWERING. Dragging a frame DOWN into ours to win the argument moves
--     things that sit above us for reasons of their own -- a confirmation
--     dialog, a popup -- and hides them behind an auction window.
--   * A HARDCODED BAG COUNT. The bag frames are numbered and how many exist
--     is the client's business.

package.path = "tests/support/?.lua;" .. package.path
local H = require("harness")

-- The UI half lives in ui/frame.lua, which no suite loads. Extracted at run
-- time rather than copied; a copy drifts.
local SRC = "ui/frame.lua"
local function extract(signature)
    local f = assert(io.open(SRC, "r"), "run this from the repo root")
    local src = f:read("*a")
    f:close()
    local body, grabbing = {}, false
    for line in string.gfind(src, "([^\n]*)\n") do
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
    "function ui.StrataRank(",
    "function ui.RaiseFrameNames(",
    "function ui.JoinRaiseGroup(",
}) do
    local fn, err = loadstring(extract(sig), sig)
    if not fn then error(sig .. " will not compile: " .. tostring(err)) end
    fn()
end

-- ---------------------------------------------------------------------------
H.section("the client's strata order")
-- ---------------------------------------------------------------------------

-- IT IS THE CLIENT'S ORDER AND NOT OURS TO REARRANGE. FULLSCREEN sits ABOVE
-- DIALOG, which looks wrong written down and is what the client does -- so it
-- is asserted rather than left to whoever reads the list next.
H.check("background is below low",
        ui.StrataRank("BACKGROUND") < ui.StrataRank("LOW"))
H.check("low is below medium",
        ui.StrataRank("LOW") < ui.StrataRank("MEDIUM"))
H.check("medium is below high",
        ui.StrataRank("MEDIUM") < ui.StrataRank("HIGH"))
H.check("high is below dialog",
        ui.StrataRank("HIGH") < ui.StrataRank("DIALOG"))
H.check("dialog is below fullscreen",
        ui.StrataRank("DIALOG") < ui.StrataRank("FULLSCREEN"))
H.check("fullscreen is below fullscreen dialog",
        ui.StrataRank("FULLSCREEN") < ui.StrataRank("FULLSCREEN_DIALOG"))
H.check("...and the tooltip is above everything",
        ui.StrataRank("FULLSCREEN_DIALOG") < ui.StrataRank("TOOLTIP"))

-- ANYTHING UNKNOWN READS AS BELOW EVERYTHING, so it gets lifted rather than
-- silently left where it is. A frame whose strata we cannot place is exactly
-- the one most likely to be stuck underneath.
H.eq("an unknown strata ranks below all of them", ui.StrataRank("NONSENSE"), 0)
H.eq("...and so does none at all", ui.StrataRank(nil), 0)
H.check("a real strata outranks an unknown one",
        ui.StrataRank("LOW") > ui.StrataRank(nil))

-- ---------------------------------------------------------------------------
H.section("which frames are in the argument")
-- ---------------------------------------------------------------------------

do
    local names = ui.RaiseFrameNames(11)
    local has = {}
    local i = 1
    while i <= table.getn(names) do has[names[i]] = true; i = i + 1 end

    -- THE BAGS ARE THE WHOLE REPORT, so every one the client says exists is
    -- in the list -- not a hardcoded five, which silently drops the bank bags.
    H.check("the backpack is in", has.ContainerFrame1)
    H.check("...and the last bag the client reports", has.ContainerFrame11)
    H.check("...and nothing beyond it", not has.ContainerFrame12)

    -- Professions, named because the user asked for them by name.
    H.check("the trade skill window is in", has.TradeSkillFrame)
    H.check("...and the craft window", has.CraftFrame)

    -- ...and the rest of what is plausibly open while trading.
    H.check("the merchant is in", has.MerchantFrame)
    H.check("the bank is in", has.BankFrame)
    H.check("the mailbox is in", has.MailFrame)

    -- Nothing twice: SetToplevel is idempotent, but a duplicate in the list is
    -- a sign the list was edited without being read.
    local seen, dupe = {}, nil
    i = 1
    while i <= table.getn(names) do
        if seen[names[i]] then dupe = names[i] end
        seen[names[i]] = true
        i = i + 1
    end
    H.isNil("no frame is listed twice", dupe)
end

-- A CLIENT THAT DOES NOT SAY still gets its bags handled, rather than none.
do
    local names = ui.RaiseFrameNames(nil)
    local has = {}
    local i = 1
    while i <= table.getn(names) do has[names[i]] = true; i = i + 1 end
    H.check("an unstated bag count still covers the backpack",
            has.ContainerFrame1)
    H.check("...and the windows", has.TradeSkillFrame)
end

-- A count of three means three, so the loop is reading its argument.
do
    local names = ui.RaiseFrameNames(3)
    local has = {}
    local i = 1
    while i <= table.getn(names) do has[names[i]] = true; i = i + 1 end
    H.check("three bags means three", has.ContainerFrame3)
    H.check("...and not four", not has.ContainerFrame4)
end

-- ---------------------------------------------------------------------------
H.section("joining the group")
-- ---------------------------------------------------------------------------

-- A stand-in for a client frame: it records what was done to it, which is the
-- only way to tell "raised it" apart from "left it alone".
local function frame(strata, canToplevel)
    local f = { strata = strata, toplevel = nil, sets = 0 }
    function f:GetFrameStrata() return self.strata end
    function f:SetFrameStrata(s) self.strata = s; self.sets = self.sets + 1 end
    if canToplevel ~= false then
        function f:SetToplevel(v) self.toplevel = v end
    end
    return f
end

-- LIFTED, because toplevel only reorders within a strata -- a frame a whole
-- strata below ours can be clicked all day and never come forward. This is
-- the half that makes the flag mean anything.
do
    local bag = frame("MEDIUM")
    H.check("a frame below ours joins", ui.JoinRaiseGroup(bag, "HIGH"))
    H.eq("...and is lifted into our strata", bag.strata, "HIGH")
    H.check("...and learns to raise itself", bag.toplevel)
end

-- RAISED, NEVER LOWERED. A frame above us is there for a reason that has
-- nothing to do with this argument, and pulling it down is how an addon ends
-- up hiding the box asking whether you really meant to spend that gold.
do
    local dialog = frame("DIALOG")
    H.check("a frame above ours joins too", ui.JoinRaiseGroup(dialog, "HIGH"))
    H.eq("...but keeps its strata", dialog.strata, "DIALOG")
    H.eq("...and nothing was set", dialog.sets, 0)
    H.check("...and it still learns to raise itself", dialog.toplevel)
end

-- Already alongside us: nothing to do but the flag.
do
    local peer = frame("HIGH")
    H.check("a frame beside ours joins", ui.JoinRaiseGroup(peer, "HIGH"))
    H.eq("...and is not re-set", peer.sets, 0)
    H.check("...and raises itself", peer.toplevel)
end

-- A frame with no strata at all reads as below everything and is lifted.
do
    local odd = frame(nil)
    ui.JoinRaiseGroup(odd, "HIGH")
    H.eq("a frame with no strata is lifted", odd.strata, "HIGH")
end

-- WHAT IS NOT THERE IS NOT AN ERROR. Half these frames are load-on-demand and
-- simply do not exist until the player has opened that window once, which is
-- why this runs again rather than once at startup.
H.check("a frame that does not exist is skipped",
        not ui.JoinRaiseGroup(nil, "HIGH"))
H.check("...and so is something that is not a frame",
        not ui.JoinRaiseGroup(frame("HIGH", false), "HIGH"))

-- No target strata: still worth the flag, just nothing to lift into.
do
    local bag = frame("MEDIUM")
    H.check("no target strata still joins", ui.JoinRaiseGroup(bag, nil))
    H.eq("...without moving it", bag.strata, "MEDIUM")
    H.check("...and it raises itself", bag.toplevel)
end

-- ---------------------------------------------------------------------------
H.section("...and it is actually applied")
-- ---------------------------------------------------------------------------

-- THE HALF A PURE FUNCTION CANNOT PROVE. All of the above can be perfect and
-- change nothing on screen if nothing ever calls it -- and the two moments it
-- has to run at are the two that are easy to leave out: a load-on-demand
-- window appearing, and the auction house opening the backpack for you.
do
    local f = assert(io.open(SRC, "r"), "run this from the repo root")
    local body = f:read("*a")
    f:close()
    local function says(needle)
        return string.find(body, needle, 1, true) ~= nil
    end

    H.check("the window applies it when it is built",
            says("    ui.frame = f\n"
              .. "    -- Everything else that can be on screen while trading"))
    H.check("...a load-on-demand window gets it when it arrives",
            says('if loadedName and string.find(string.lower(loadedName),'
              .. ' "blizzard_", 1, true)'))
    H.check("...and the auction house applies it as it opens",
            says("    ui.OpenWindow()\n"
              .. "    -- The client opens your BACKPACK here"))

    -- Counted, so a call cannot be deleted and leave the others looking like
    -- enough.
    local n, at = 0, 1
    while true do
        local found = string.find(body, "ui.ApplyRaiseGroup()", at, true)
        if not found then break end
        n = n + 1
        at = found + 1
    end
    H.check("it is applied at every moment it has to be", n >= 4, n)

    -- OUR OWN STRATA IS THE TARGET, read rather than written down: a second
    -- copy of "HIGH" is one more place to change and forget.
    H.check("the target strata is read from our own window",
            says("strata = ui.frame:GetFrameStrata() or strata"))

    -- NOTHING IS HOOKED. There is no OnMouseDown to save and replace here --
    -- these are widget settings the client acts on by itself -- and a hook
    -- would be one more thing to fight another addon over.
    local at2 = string.find(body, "function ui.ApplyRaiseGroup(", 1, true)
    local stop = string.find(body, "\nend\n", at2, true)
    local fn = string.sub(body, at2, stop)
    H.check("...without hooking anything",
            string.find(fn, "hooksecurefunc", 1, true) == nil
            and string.find(fn, "SetScript", 1, true) == nil)
end

os.exit(H.report("raise"))
