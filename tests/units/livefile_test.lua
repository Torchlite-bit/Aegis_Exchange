-- Aegis: Exchange -- tests/units/livefile_test.lua
--
-- The live file for tools outside the game (ROADMAP 6.3, issue #85).
--
-- Asked for as: "a text log file that is written to live (not on logout or
-- anything like that) for each craft that is done that can be consumed by
-- other tools ... expanded to everything bought / sold also and at what
-- price". Built on the owner's condition that it cost next to nothing: "ram
-- usage is limited".
--
-- What this pins:
--   * without SuperWoW's ExportFile nothing runs at all;
--   * the file: one line per record, TAB-separated, this character's
--     cooldowns and its last live.EVENTS_MAX crafts, sales and buys, oldest
--     first, nobody else's;
--   * WHEN it is written, which is the cost: never inline, once per burst,
--     never in combat, no later than live.MAX_WAIT into a steady stream,
--     before logout, once at login -- and not at all for a profession window
--     re-read that changed nothing;
--   * a failing write says so once, and /aex diag can say what a write cost.
--
-- No client and no SuperWoW here: ExportFile is a stand-in that keeps what it
-- was given.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)
local db, craft, live = A.db, A.craft, A.live

local NOW = 1700000000
local ME = db.CharKey()

-- A tick the way the CLIENT runs one: OnUpdate fires only on a SHOWN frame.
local function frameTick(fr)
    if fr:IsShown() then W.Tick(fr) end
end

-- Let `seconds` pass, ticking the driver along the way.
local function wait(seconds)
    local t = 0
    while t < seconds do
        W.Advance(0.5)
        frameTick(live.driver)
        t = t + 0.5
    end
end

local function lines(text)
    local out = {}
    for l in string.gfind(text, "([^\n]*)\n") do table.insert(out, l) end
    return out
end

-- The fields of one line. Empty fields count: "a\t\tb" is three.
local function fields(line)
    local out = {}
    for f in string.gfind(line .. "\t", "([^\t]*)\t") do table.insert(out, f) end
    return out
end

local function linesOf(text, kind)
    local out = {}
    local all = lines(text)
    local i = 1
    while i <= table.getn(all) do
        if fields(all[i])[1] == kind then table.insert(out, fields(all[i])) end
        i = i + 1
    end
    return out
end

-- ---------------------------------------------------------------------------
H.section("Without SuperWoW nothing runs")
-- ---------------------------------------------------------------------------

ExportFile = nil
H.check("no ExportFile, not available", not live.Available())
db.RecordTxn("sale", "Linen Cloth", 1900, 2589, 20)
H.check("a sale marks nothing", next(live.pending) == nil)
H.check("...and wakes nothing", not live.driver:IsShown())
H.check("diag says why it is off", string.find(live.DiagLine(), "no SuperWoW", 1, true) ~= nil)
H.check("/aex live says what it needs",
        string.find(live.Command(""), "needs SuperWoW", 1, true) ~= nil)
H.eq("...and changes no setting", db.account.settings and db.account.settings.liveFile, nil)

-- The stand-in: keeps every write.
local writes = {}
ExportFile = function(name, text)
    table.insert(writes, { name = name, text = text })
end
H.check("with ExportFile, available", live.Available())
H.check("...and on by default", live.Enabled())

-- ---------------------------------------------------------------------------
H.section("The file: this character's cooldowns and trades, one per line")
-- ---------------------------------------------------------------------------

local ledger = {
    { t = NOW - 500, kind = "buy", item = "Linen Cloth", amount = 400, id = 2589, qty = 20 },
    { t = NOW - 400, kind = "sale", item = "Silk Cloth", amount = 900, id = 4306 },
    { t = NOW - 300, kind = "sale", item = "Silk Cloth", amount = 950, id = 4306, qty = 5, who = ME },
    { t = NOW - 200, kind = "buy", item = "Iron Bar", amount = 1200, id = 3575, qty = 10, who = "Bronn" },
    { t = NOW - 100, kind = "sale", item = db.VENDOR_SALE_PREFIX .. "3 stacks)", amount = 75, who = ME },
    { t = NOW - 50, kind = "buy", item = "Thorium\tBar", amount = 3000, id = 12359, qty = 4, who = ME },
}
local crafts = {
    { t = NOW - 250, id = 12360, item = "Arcanite Bar", n = 1 },
}
local c = { name = ME, realm = "TestRealm", class = "MAGE", recipes = {
    ["Transmute: Arcanite"] = { ready = NOW + 3600, prof = "Alchemy", item = 12360 },
    ["Mooncloth"] = { ready = NOW - 60, prof = "Tailoring" },
} }
local text = live.Build(c, ledger, crafts, NOW, "9.9.9")
local all = lines(text)

H.check("it starts with what it is", string.find(all[1], "^# Aegis: Exchange live file, format 1") ~= nil)
H.check("...says how to read it", string.find(text, "# Fields are separated by TABs", 1, true) ~= nil)
H.eq("...and ends with a line break", string.sub(text, -1), "\n")
H.listEq("the character: name, realm, class, written, version",
         linesOf(text, "character")[1], { "character", ME, "TestRealm", "MAGE", tostring(NOW), "9.9.9" })

local cds = linesOf(text, "cooldown")
H.eq("both cooldowns", table.getn(cds), 2)
H.listEq("by name, each with its profession, ready time and item",
         cds[1], { "cooldown", "Mooncloth", "Tailoring", tostring(NOW - 60), "" })
H.listEq("...an item it makes, where known",
         cds[2], { "cooldown", "Transmute: Arcanite", "Alchemy", tostring(NOW + 3600), "12360" })

-- The trades, and only this character's: oldest first, a craft in its place.
local kinds = {}
local i = 1
while i <= table.getn(all) do
    local k = fields(all[i])[1]
    if k == "craft" or k == "sale" or k == "buy" or k == "vendor" then
        table.insert(kinds, k)
    end
    i = i + 1
end
H.listEq("this character's trades and crafts, oldest first",
         kinds, { "sale", "craft", "vendor", "buy" })
H.listEq("a craft: time, item id, item, count",
         linesOf(text, "craft")[1], { "craft", tostring(NOW - 250), "12360", "Arcanite Bar", "1" })
H.listEq("a sale: time, item id, item, count, copper",
         linesOf(text, "sale")[1], { "sale", tostring(NOW - 300), "4306", "Silk Cloth", "5", "950" })
H.listEq("a vendor lump is a vendor line, its count unknown",
         linesOf(text, "vendor")[1],
         { "vendor", tostring(NOW - 100), "", db.VENDOR_SALE_PREFIX .. "3 stacks)", "", "75" })
H.listEq("a tab inside a name cannot split the record",
         linesOf(text, "buy")[1], { "buy", tostring(NOW - 50), "12359", "Thorium Bar", "4", "3000" })
H.check("another character's trade is not in it", string.find(text, "Iron Bar", 1, true) == nil)
H.check("...nor one from before trades named a character",
        string.find(text, "Linen Cloth", 1, true) == nil)

-- A count nobody knows stays empty -- never 1.
local unknown = live.Build(c, { { t = NOW, kind = "sale", item = "Wool Cloth",
                                  amount = 600, id = 2592, who = ME } }, {}, NOW, "x")
H.listEq("an unknown count is an empty field",
         linesOf(unknown, "sale")[1], { "sale", tostring(NOW), "2592", "Wool Cloth", "", "600" })

-- The cap: the newest live.EVENTS_MAX, across both sources.
local big, many = {}, {}
local k = 1
while k <= 150 do
    table.insert(big, { t = NOW + 2 * k, kind = "sale", item = "S" .. k, amount = k, who = ME })
    k = k + 1
end
k = 1
while k <= 30 do
    table.insert(many, { t = NOW + 2 * k + 1, id = 1, item = "C" .. k, n = 1 })
    k = k + 1
end
local ev = live.Events(big, many, ME, live.EVENTS_MAX)
H.eq("never more than the cap", table.getn(ev), live.EVENTS_MAX)
H.eq("...the newest ones: the last is the newest sale", ev[table.getn(ev)].item, "S150")
H.eq("...and the first is the 100th newest", ev[1].item, "S51")
H.eq("crafts older than the window are left out with the rest",
     table.getn(linesOf(live.Build(c, big, many, NOW, "x"), "craft")), 0)

H.eq("a file name: realm, then character",
     live.FileName("Tel'Abim", "Merrily"), "AegisExchange-Tel'Abim-Merrily")
H.eq("...without what Windows refuses in one",
     live.FileName("A:B/C", "D?\"E"), "AegisExchange-ABC-DE")

-- ---------------------------------------------------------------------------
H.section("When it is written: once per burst, never inline")
-- ---------------------------------------------------------------------------

db.ClearLedger()
writes = {}
k = 1
while k <= 40 do
    db.RecordTxn("buy", "Linen Cloth", 100, 2589, 20)
    k = k + 1
end
H.eq("forty buyouts write nothing inline", table.getn(writes), 0)
H.check("...and wake the driver", live.driver:IsShown())
wait(1.5)
H.eq("nothing inside the quiet time", table.getn(writes), 0)
wait(1)
H.eq("...then ONE write", table.getn(writes), 1)
H.check("the driver idles after it", not live.driver:IsShown())
H.eq("...to this character's file", writes[1].name, "AegisExchange-TestRealm-" .. ME)
H.eq("...holding all forty", table.getn(linesOf(writes[1].text, "buy")), 40)
wait(5)
H.eq("and not again while nothing changes", table.getn(writes), 1)

-- A steady stream -- one sale every 1.5 seconds -- never goes quiet for two.
writes = {}
k = 1
while k <= 10 do
    db.RecordTxn("sale", "Silk Cloth", 900, 4306, 5)
    wait(1.5)
    k = k + 1
end
H.check("a steady stream still lands by the longest wait",
        table.getn(writes) >= 1 and table.getn(writes) <= 2)

-- ---------------------------------------------------------------------------
H.section("Never in combat")
-- ---------------------------------------------------------------------------

wait(12)
writes = {}
local fighting = true
UnitAffectingCombat = function(unit) return unit == "player" and fighting end
db.RecordTxn("sale", "Wool Cloth", 600, 2592, 20)
wait(4)
H.eq("a write due in combat waits", table.getn(writes), 0)
H.check("...asleep, not polling every frame of the fight", not live.driver:IsShown())
H.check("...and diag says so", string.find(live.DiagLine(), "waiting for combat", 1, true) ~= nil)
fighting = false
W.FireEvent(A.frame, "PLAYER_REGEN_ENABLED")
H.check("the fight ends: awake", live.driver:IsShown())
frameTick(live.driver)
H.eq("...and it is written", table.getn(writes), 1)

-- ---------------------------------------------------------------------------
H.section("Before logout, and once at login")
-- ---------------------------------------------------------------------------

writes = {}
db.RecordTxn("sale", "Mageweave Cloth", 1500, 4338, 20)
W.FireEvent(A.frame, "PLAYER_LOGOUT")
H.eq("a change inside the quiet time is written at logout", table.getn(writes), 1)
writes = {}
W.FireEvent(A.frame, "PLAYER_LOGOUT")
H.eq("...and logout with nothing due writes nothing", table.getn(writes), 0)

W.FireEvent(A.frame, "PLAYER_ENTERING_WORLD")
wait(5)
H.eq("login writes nothing in the login rush", table.getn(writes), 0)
wait(11)
H.eq("...and once after it, so the file exists before anything changes",
     table.getn(writes), 1)
W.FireEvent(A.frame, "PLAYER_ENTERING_WORLD")
wait(20)
H.eq("a loading screen is not a login", table.getn(writes), 1)

-- A change soon after login does not wait out the login delay.
live.loggedIn = nil
writes = {}
W.FireEvent(A.frame, "PLAYER_ENTERING_WORLD")
db.RecordTxn("buy", "Iron Bar", 1200, 3575, 10)
wait(3)
H.eq("a sale after login is written on the usual quiet", table.getn(writes), 1)
wait(20)
H.eq("...and the login write is not added on top", table.getn(writes), 1)
-- ...and the other way round: login does not put off a write already due.
live.loggedIn = nil
writes = {}
db.RecordTxn("buy", "Iron Bar", 1200, 3575, 10)
W.FireEvent(A.frame, "PLAYER_ENTERING_WORLD")
wait(3)
H.eq("a write already due is not pushed back by login", table.getn(writes), 1)

-- ---------------------------------------------------------------------------
H.section("Cooldowns: a write when one moves, not when a window opens")
-- ---------------------------------------------------------------------------

local me = db.MyCooldowns("MAGE")
local row = { { name = "Transmute: Arcanite", remaining = 3600.4, itemId = 12360 } }
local known = {}
H.check("a new cooldown is a change", craft.ApplyCooldownScan(me, row, "Alchemy", known, NOW))
-- A minute on, the client's figure lands a second short of the first read's:
-- time() is whole seconds and the cooldown is not.
row[1].remaining = 3539.6
H.check("the same cooldown read a minute later is not",
        not craft.ApplyCooldownScan(me, row, "Alchemy", known, NOW + 60))
H.eq("...and the stored time stays put", me.recipes["Transmute: Arcanite"].ready, NOW + 3601)
row[1].remaining = 86400
H.check("a cooldown started again is", craft.ApplyCooldownScan(me, row, "Alchemy", known, NOW + 7200))
row[1].remaining = nil
H.check("one that has ended is", craft.ApplyCooldownScan(me, row, "Alchemy", known, NOW + 90000))
H.check("...and reading it ready again is not",
        not craft.ApplyCooldownScan(me, row, "Alchemy", known, NOW + 99000))

-- The capture, taken out of ui/frame.lua and run: a window opened on nothing
-- new marks no file.
do
    local f = assert(io.open("ui/frame.lua", "r"), "run this from the repo root")
    local src = f:read("*a")
    f:close()
    local at = assert(string.find(src, "function ui.CaptureCooldowns()", 1, true))
    local stop = assert(string.find(src, "\nend\n", at, true))
    ui = {}
    _G.A = A
    assert(loadstring(string.sub(src, at, stop + 4)))()
end
GetTradeSkillLine = function() return "Alchemy", 300, 300 end
GetNumTradeSkills = function() return 1 end
GetTradeSkillInfo = function() return "Transmute: Arcanite", "optimal" end
local cdLeft = 3000.2
GetTradeSkillCooldown = function() return cdLeft end
GetTradeSkillItemLink = function() return "|Hitem:12360:0:0:0|h[Arcanite Bar]|h" end
W.now = NOW + 200000
wait(12)
writes = {}
ui.CaptureCooldowns()
H.check("a cooldown seen for the first time marks the file", live.due ~= nil)
wait(3)
H.eq("...which is written", table.getn(writes), 1)
local cdLine = linesOf(writes[1].text, "cooldown")[1]
H.eq("...with the ready time in it", cdLine and cdLine[4], tostring(NOW + 200000 + 3001))
W.now = NOW + 200060
cdLeft = 2940.6
ui.CaptureCooldowns()
H.check("the window read again a minute on marks nothing", live.due == nil)
W.now = NOW

-- ---------------------------------------------------------------------------
H.section("Crafts, a forget, and the setting")
-- ---------------------------------------------------------------------------

writes = {}
db.CraftLog(ME)  -- reading creates nothing
H.eq("no craft log until something is made", table.getn(db.CraftLog(ME)), 0)
W.FireEvent(A.frame, "CHAT_MSG_LOOT",
    "You create: |cffffffff|Hitem:12360:0:0:0|h[Arcanite Bar]|h|r.")
local made = db.CraftLog(ME)
H.eq("a craft is logged", table.getn(made), 1)
H.eq("...by name, read off the link", made[1] and made[1].item, "Arcanite Bar")
H.eq("...with its item id", made[1] and made[1].id, 12360)
wait(3)
H.eq("...and written", table.getn(writes), 1)
H.eq("...as a craft line", table.getn(linesOf(writes[1].text, "craft")), 1)
W.FireEvent(A.frame, "CHAT_MSG_LOOT", "You receive loot: |cffffffff|Hitem:2589:0:0:0|h[Linen Cloth]|h|r.")
H.eq("loot is not a craft", table.getn(db.CraftLog(ME)), 1)
k = 1
while k <= db.CRAFTS_MAX + 20 do
    db.RecordCraft(3577, "Gold Bar", 1, NOW + k)
    k = k + 1
end
H.eq("the craft log is capped", table.getn(db.CraftLog(ME)), db.CRAFTS_MAX)
H.eq("...keeping the newest", db.CraftLog(ME)[db.CRAFTS_MAX].t, NOW + db.CRAFTS_MAX + 20)

-- A forget is made from one character about another: THAT file is due.
wait(12)
writes = {}
db.Cooldowns()["Bronn"] = { class = "WARRIOR", recipes = {
    ["Mooncloth"] = { ready = NOW, prof = "Tailoring" },
    ["Salt"] = { ready = NOW, prof = "Leatherworking" } } }
H.check("a forget", db.ForgetCooldown("Bronn", "Mooncloth"))
wait(3)
H.eq("...writes the file of the character it was about",
     writes[1] and writes[1].name, "AegisExchange-TestRealm-Bronn")
H.listEq("...with what is left", linesOf(writes[1].text, "character")[1],
         { "character", "Bronn", "TestRealm", "WARRIOR", tostring(NOW), A.version })

-- Off: nothing marked, nothing due.
wait(12)
writes = {}
db.RecordTxn("buy", "Iron Bar", 1200, 3575, 10)
H.check("/aex live turns it off", string.find(live.Command(""), "OFF", 1, true) ~= nil)
H.eq("...stored as the setting", db.Setting("liveFile"), false)
wait(5)
H.eq("...dropping what was due", table.getn(writes), 0)
db.RecordTxn("buy", "Iron Bar", 1200, 3575, 10)
H.check("...and marking nothing after", next(live.pending) == nil)
H.check("diag says it is off", string.find(live.DiagLine(), "off", 1, true) ~= nil)
H.check("/aex live on", string.find(live.Command("on"), "imports\\AegisExchange-TestRealm-" .. ME .. ".txt", 1, true) ~= nil)
wait(3)
H.eq("...writes the file straight away", table.getn(writes), 1)
H.check("/aex live on, again, stays on", string.find(live.Command("on"), "ON", 1, true) ~= nil)
H.check("any other word is a status line, changing nothing",
        string.find(live.Command("status"), "live file: on", 1, true) ~= nil
        and db.Setting("liveFile") == true)

-- Demo mode invents a ledger for the screen. None of it is real, and none of
-- it may reach a file another program trusts.
wait(12)
writes = {}
db.demo = true
db.demoLedger = nil
db.ClearLedger()
W.now = NOW + 1000      -- newer than the hundred crafts above
db.RecordTxn("sale", "Real Cloth", 100, 1, 1)
wait(3)
db.demo = false
W.now = NOW
local demoSales = linesOf(writes[1].text, "sale")
H.eq("demo mode writes only what really happened", table.getn(demoSales), 1)
H.eq("...the real sale", demoSales[1] and demoSales[1][4], "Real Cloth")

-- ---------------------------------------------------------------------------
H.section("A failing write, and what a write costs")
-- ---------------------------------------------------------------------------

wait(12)
local okExport = ExportFile
ExportFile = function() error("imports folder missing") end
W.messages = {}
live.warned = nil
db.RecordTxn("sale", "Wool Cloth", 600, 2592, 20)
wait(3)
db.RecordTxn("sale", "Wool Cloth", 600, 2592, 20)
wait(3)
H.eq("two failures counted", live.stats.failures, 2)
H.eq("...said in chat once, not per sale", table.getn(W.messages), 1)
H.check("...naming what went wrong", string.find(W.messages[1] or "", "imports folder missing", 1, true) ~= nil)
H.check("diag names it too", string.find(live.DiagLine(), "FAILED 2x", 1, true) ~= nil)
ExportFile = okExport

-- The clock: debugprofilestop where there is one, GetTime otherwise.
local ms = 0
debugprofilestop = function() ms = ms + 0.25; return ms end
H.check("a write", live.WriteChar(ME))
H.eq("the build is timed", live.stats.buildMs, 0.25)
H.eq("...and the write", live.stats.writeMs, 0.25)
H.check("diag prints the cost and the clock",
        string.find(live.DiagLine(), "written 0.25 ms", 1, true) ~= nil
        and string.find(live.DiagLine(), "clock: debugprofilestop", 1, true) ~= nil)
debugprofilestop = nil
local _, name = live.Clock()
H.eq("without it, GetTime", name, "GetTime")

-- ---------------------------------------------------------------------------
H.section("Clear price data clears prices")
-- ---------------------------------------------------------------------------

db.RecordAuction(2589, 100, "Linen Cloth")
local bucket = db.account.realms[db.realmKey]
H.check("prices recorded", bucket.items ~= nil and next(bucket.items) ~= nil)
db.ClearItems()
H.check("cleared", bucket.items == nil or next(bucket.items) == nil)
H.check("...the cooldowns are still there", next(db.Cooldowns()) ~= nil)
H.eq("...and so is what was made", table.getn(db.CraftLog(ME)), db.CRAFTS_MAX)

-- ---------------------------------------------------------------------------
H.section("Wired into the slash command")
-- ---------------------------------------------------------------------------

do
    local f = assert(io.open("ui/frame.lua", "r"))
    local src = f:read("*a")
    f:close()
    local function has(needle) return string.find(src, needle, 1, true) ~= nil end
    H.check("/aex live, the whole word",
            has('local _, _, liveArg = string.find(cmd, "^%s*live%s*(%a*)%s*$")')
            and has("        ChatMsg(A.live.Command(liveArg))"))
    H.check("/aex diag prints what a write cost",
            has('        if A.live then ChatMsg("  " .. A.live.DiagLine()) end'))
    local _, _, word = string.find("live off", "^%s*live%s*(%a*)%s*$")
    H.eq("...which reads the word after it", word, "off")
    H.isNil("...and never a word that merely contains it",
            string.find("delivery", "^%s*live%s*(%a*)%s*$"))
end

os.exit(H.report("livefile"))
