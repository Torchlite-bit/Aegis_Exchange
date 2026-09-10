-- Aegis: Exchange -- tests/units/craftqueue_test.lua
--
-- The sequential-search runner behind "Price" and "Price all".
--
-- ONE runner for both, because two copies of "search these names in turn"
-- drift: one grows a cancel and the other does not, one clears its queue when
-- the auction house refuses and the other leaves it armed for ever. Same
-- lesson as the Sell tab's headers and rows, applied to behaviour.
--
-- The interesting case is a REPLY THAT ARRIVES LATE. Every search here is
-- asynchronous -- the results land whenever the client feels like it -- so a
-- player who presses Stop, or starts a different run, can have the previous
-- run's callback fire afterwards. Chaining off it restarts a walk they
-- cancelled, and no amount of reading the code makes that obvious.

package.path = "tests/support/?.lua;" .. package.path
local H = require("harness")

local function Source()
    local f = assert(io.open("ui/frame.lua", "r"), "run this from the repo root")
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
A  = { buy = {} }
for _, sig in ipairs({
    "function ui.CraftQueueRunning(",
    "function ui.CancelCraftQueue(",
    "function ui.StartCraftQueue(",
    "function ui.RunCraftQueue(",
    "function ui.RefreshCraftButtons(",
}) do
    local fn, err = loadstring(extract(sig), sig)
    if not fn then error(sig .. " will not compile: " .. tostring(err)) end
    fn()
end

-- The real one, kept before Reset() stubs it over -- the section at the foot
-- of this file puts it back to test which buttons it gates.
REAL_REFRESH = ui.RefreshCraftButtons

-- The surface the runner touches, stubbed. Every one of these is a widget or
-- a repaint in the real thing and none of them decides anything.
local function Reset()
    ui.craftQueue = nil
    ui.craftResults = nil
    ui.sent = {}                 -- the terms the runner asked for, in order
    ui.pending = {}              -- their onResults callbacks, unfired
    ui.craftBox   = { SetText = function() end }
    ui.craftTitle = { SetText = function() end }
    ui.craftStatus = { text = "", SetText = function(self, t) self.text = t end }
    ui.UpdateCraftList = function() end
    ui.UpdateCraftSummary = function() end
    ui.RefreshCraftStatus = function() end
    ui.RefreshCraftButtons = function() end
    A.buy.Search = function(term, cb)
        table.insert(ui.sent, term)
        table.insert(ui.pending, cb.onResults)
        return true
    end
end

-- Deliver the reply for the Nth search the runner made.
local function Reply(n)
    local cb = ui.pending[n]
    if cb then cb({}) end
end

-- ---------------------------------------------------------------------------
H.section("a queue walks its names in order")
-- ---------------------------------------------------------------------------

Reset()
H.check("nothing is running to start with", not ui.CraftQueueRunning(),
        "a queue exists before one was asked for")

H.check("starting a queue reports success",
        ui.StartCraftQueue({ "A", "B", "C" }, "Shopping"), "it refused")
H.check("...and it is running", ui.CraftQueueRunning(), "not running")
H.eq("the FIRST name is searched immediately", table.getn(ui.sent), 1)
H.eq("...and it is the first one", ui.sent[1], "A")

-- ONE AT A TIME. The next search starts when the previous one's results land,
-- which is what paces the walk against the client's query gate.
H.eq("nothing else is searched yet", table.getn(ui.sent), 1)
Reply(1)
H.eq("the reply starts the next one", table.getn(ui.sent), 2)
H.eq("...and it is the second name", ui.sent[2], "B")
Reply(2)
H.eq("and the third", ui.sent[3], "C")

local finished = false
ui.craftQueue.done = function() finished = true end
Reply(3)
H.check("the queue ends when the names run out", not ui.CraftQueueRunning(),
        "still running")
H.check("...and says so", finished, "the done callback never fired")
H.eq("nothing further is searched", table.getn(ui.sent), 3)

-- ---------------------------------------------------------------------------
H.section("a reply that arrives after the player stopped")
-- ---------------------------------------------------------------------------

-- THE GUARD THIS SUITE EXISTS FOR. Press Stop while a search is in flight and
-- its reply still lands. Chaining off it restarts the walk that was
-- cancelled -- and the player pressed Stop precisely because they wanted it to
-- stop.
Reset()
ui.StartCraftQueue({ "A", "B", "C" }, "Shopping")
H.eq("one search is in flight", table.getn(ui.sent), 1)

ui.CancelCraftQueue()
H.check("cancelling stops the queue", not ui.CraftQueueRunning(), "still running")

Reply(1)          -- the in-flight search answers AFTER the cancel
H.check("a late reply does not restart it", not ui.CraftQueueRunning(),
        "the cancelled walk resumed")
H.eq("...and searches nothing more", table.getn(ui.sent), 1)

-- ...and the same for a reply belonging to a run the player REPLACED. Pricing
-- a recipe while a shopping walk is in flight is one click away.
Reset()
ui.StartCraftQueue({ "A", "B" }, "Shopping")
ui.StartCraftQueue({ "X", "Y" }, "Pricing")
H.eq("the second run starts its own first search", ui.sent[2], "X")
Reply(1)          -- the FIRST run's reply, now stale
H.eq("the stale reply advances nothing", table.getn(ui.sent), 2)
Reply(2)          -- the live run's reply
H.eq("the live run carries on", ui.sent[3], "Y")

-- ---------------------------------------------------------------------------
H.section("when the auction house refuses")
-- ---------------------------------------------------------------------------

-- A queue left armed after a refusal fires against whatever session comes
-- next, which may be a different trip to a different auctioneer.
Reset()
A.buy.Search = function() return false end
ui.StartCraftQueue({ "A", "B", "C" }, "Shopping")
H.check("a refusal ends the queue", not ui.CraftQueueRunning(),
        "the queue is still armed after the client said no")
H.check("...and says so on the status line",
        string.find(ui.craftStatus.text, "busy", 1, true) ~= nil,
        "status reads: " .. tostring(ui.craftStatus.text))

Reset()
H.check("an empty list does not start a queue",
        not ui.StartCraftQueue({}, "Shopping"), "it started on nothing")
H.check("...and nil too", not ui.StartCraftQueue(nil, "Shopping"),
        "it started on nil")

-- ---------------------------------------------------------------------------
H.section("the buttons a running walk takes away")
-- ---------------------------------------------------------------------------

-- ui.RefreshCraftButtons is the REAL one here, not the stub the runner tests
-- use: what is under test is which buttons it gates, and the buttons are four
-- tables with the three methods it calls.
local function FakeBtn()
    return { on = true, text = nil,
             SetText = function(self, t) self.text = t end,
             Enable  = function(self) self.on = true end,
             Disable = function(self) self.on = false end }
end

local function ArmButtons()
    Reset()
    ui.RefreshCraftButtons = REAL_REFRESH
    ui.craftPriceAllBtn = FakeBtn()
    ui.craftPriceBtn = FakeBtn()
    ui.craftDelBtn   = FakeBtn()
    ui.craftResetBtn = FakeBtn()
end

ArmButtons()
ui.RefreshCraftButtons()
H.eq("idle, the button offers to price the list",
     ui.craftPriceAllBtn.text, "Price all")
H.check("...and the other three are live",
        ui.craftPriceBtn.on and ui.craftDelBtn.on and ui.craftResetBtn.on,
        "something was disabled with no walk running")

ui.StartCraftQueue({ "Dreamfoil", "Gromsblood" }, "Shopping")
-- ONE BUTTON THAT BOTH STARTS AND STOPS, painted FROM the queue so the two
-- cannot get out of step.
H.eq("a running walk turns it into Stop", ui.craftPriceAllBtn.text, "Stop")

-- ALL THREE OTHERS GO. `Price` would start a second walk over the first;
-- `Remove` would delete the recipe whose reagents the walk is still searching
-- for, leaving a queue of names nothing wants -- each one a trip through the
-- query gate spent on nothing; `Reset` clears the counts the walk is filling.
-- Only `Price` was gated before v1.52.23, and it is the one of the three that
-- loses nothing.
H.check("Price is gated while it runs", not ui.craftPriceBtn.on,
        "a second walk could be started over the first")
H.check("Remove is gated while it runs", not ui.craftDelBtn.on,
        "the recipe being shopped for could be deleted mid-walk")
H.check("Reset is gated while it runs", not ui.craftResetBtn.on,
        "the made counts the walk is filling could be cleared")

ui.CancelCraftQueue()
H.eq("stopping gives the button back",
     ui.craftPriceAllBtn.text, "Price all")
H.check("...and all three come back with it",
        ui.craftPriceBtn.on and ui.craftDelBtn.on and ui.craftResetBtn.on,
        "a button stayed disabled after the walk stopped")

-- ...and it survives being called before the widgets exist. The builder calls
-- it while it is still creating them, and ui.CancelCraftQueue can be reached
-- without a Crafting tab having been built at all.
ArmButtons()
ui.craftPriceAllBtn, ui.craftPriceBtn = nil, nil
ui.craftDelBtn, ui.craftResetBtn = nil, nil
H.survives("no buttons yet is not a crash", function()
    ui.RefreshCraftButtons()
end)

os.exit(H.report("craftqueue"))
