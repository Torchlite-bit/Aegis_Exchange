-- Aegis: Exchange -- tests/units/cooldowns_test.lua
--
-- Profession cooldowns across characters (ROADMAP Phase 6, issue #85).
--
-- Asked for as: "for crafts with cooldown I would like to know when to log on
-- to that character to do those crafts. I have multiple alts doing this."
--
-- What this pins:
--   * the store keeps a READY TIME, never time remaining -- remaining means
--     nothing once you log out, which is when this is read;
--   * a recipe is learned as having a cooldown by being SEEN on one, and from
--     then on a character whose window lists it can say "ready now";
--   * a ready time already in the past is kept, not pushed to now;
--   * the list puts everything ready first, then soonest;
--   * the login line names who and what, says nothing when nothing is ready,
--     and comes once per session, not per loading screen;
--   * TRADE_SKILL_UPDATE storms: the window is read once a frame at most, and
--     a "You create:" line alone never starts a cooldown.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)
local db, craft = A.db, A.craft

local NOW = 1700000000
local H1, D1 = 3600, 86400

-- ---------------------------------------------------------------------------
H.section("The store: per realm, a ready time, and the class for the colour")
-- ---------------------------------------------------------------------------

local all = db.Cooldowns()
H.check("cooldowns have a table", type(all) == "table")
local rec = db.MyCooldowns("MAGE")
H.check("this character gets a record", rec and type(rec.recipes) == "table")
H.eq("...with its class kept for the name colour", rec.class, "MAGE")
H.check("...stored under its name", all[db.CharKey()] == rec)
H.check("it lives in this realm's bucket",
        db.account.realms[db.realmKey or db.RealmKey()].cooldowns == all)
H.check("learned cooldown recipes are account-wide",
        db.CooldownRecipes() == db.account.cdRecipes)

-- ---------------------------------------------------------------------------
H.section("Reading the open profession window")
-- ---------------------------------------------------------------------------

-- A window, as the client lists it: a header, two cooldown recipes (one on
-- cooldown, one ready), an ordinary recipe.
local window = {
    { "Transmutes", "header" },
    { "Transmute: Arcanite", "optimal", 47 * H1 + 0.4, "|Hitem:12360:0:0:0|h[Arcanite Bar]|h" },
    { "Transmute: Iron to Gold", "medium", nil, "|Hitem:3577:0:0:0|h[Gold Bar]|h" },
    { "Elixir of Fortitude", "trivial", nil, "|Hitem:3825:0:0:0|h[Elixir of Fortitude]|h" },
}
local profLine = "Alchemy"
local linkCalls = 0
GetTradeSkillLine = function() return profLine, 300, 300 end
GetNumTradeSkills = function() return table.getn(window) end
GetTradeSkillInfo = function(i) return window[i][1], window[i][2] end
GetTradeSkillCooldown = function(i) return window[i][3] end
GetTradeSkillItemLink = function(i)
    linkCalls = linkCalls + 1
    return window[i][4]
end

local known = {}
local rows, prof = craft.ReadCooldownWindow(known)
H.eq("the profession is named", prof, "Alchemy")
H.eq("headers are skipped: three recipes", table.getn(rows), 3)
H.check("the one on cooldown says how long", rows[1].remaining and rows[1].remaining > 0)
H.eq("...and what it makes", rows[1].itemId, 12360)
H.eq("an ordinary recipe costs no link call", linkCalls, 1)
known["Transmute: Iron to Gold"] = true
linkCalls = 0
rows = craft.ReadCooldownWindow(known)
H.eq("a recipe known to have a cooldown is linked even when ready", linkCalls, 2)
profLine = "UNKNOWN"
H.isNil("no profession window, nothing read", craft.ReadCooldownWindow({}))
profLine = "Alchemy"

-- ---------------------------------------------------------------------------
H.section("Folding a read into a character")
-- ---------------------------------------------------------------------------

local me = { recipes = {} }
known = {}
craft.ApplyCooldownScan(me, craft.ReadCooldownWindow(known), "Alchemy", known, NOW)
local arc = me.recipes["Transmute: Arcanite"]
H.eq("on cooldown: ready at now plus what is left, rounded up",
     arc and arc.ready, NOW + 47 * H1 + 1)
H.eq("...with its profession", arc and arc.prof, "Alchemy")
H.eq("...and what it makes", arc and arc.item, 12360)
H.check("...and is learned as a cooldown recipe", known["Transmute: Arcanite"])
H.isNil("a recipe never seen on cooldown is not stored", me.recipes["Transmute: Iron to Gold"])
H.isNil("...nor is an ordinary one", me.recipes["Elixir of Fortitude"])

-- Another character, whose window lists Iron to Gold READY. It joins the
-- list once any character has been seen with it on cooldown.
known["Transmute: Iron to Gold"] = true
local alt = { recipes = {} }
craft.ApplyCooldownScan(alt, craft.ReadCooldownWindow(known), "Alchemy", known, NOW)
local gold = alt.recipes["Transmute: Iron to Gold"]
H.eq("a known cooldown recipe with none running is ready now", gold and gold.ready, NOW)
-- Read again later: still ready, and still ready SINCE the first read.
craft.ApplyCooldownScan(alt, craft.ReadCooldownWindow(known), "Alchemy", known, NOW + D1)
H.eq("a ready time in the past is kept, not pushed to now",
     alt.recipes["Transmute: Iron to Gold"].ready, NOW)
-- A cooldown that has since ended reads as no cooldown: ready.
window[2][3] = nil
craft.ApplyCooldownScan(me, craft.ReadCooldownWindow(known), "Alchemy", known, NOW + 2 * D1)
H.eq("a cooldown that ended keeps the time it ended -- ready since then",
     me.recipes["Transmute: Arcanite"].ready, NOW + 47 * H1 + 1)
window[2][3] = 47 * H1 + 0.4

-- ---------------------------------------------------------------------------
H.section("The list: ready first, then soonest")
-- ---------------------------------------------------------------------------

local chars = {
    Bronn = { class = "WARRIOR", recipes = {
        ["Transmute: Arcanite"] = { ready = NOW - D1, prof = "Alchemy" },
        ["Salt"] = { ready = NOW + 5 * H1 },
    } },
    Merrily = { class = "MAGE", recipes = {
        ["Mooncloth"] = { ready = NOW + 2 * H1, prof = "Tailoring" },
    } },
    Ada = { recipes = { ["Mooncloth"] = { ready = NOW - 60 } } },
}
local list = craft.CooldownRows(chars, NOW, "Merrily")
H.eq("four cooldowns", table.getn(list), 4)
H.eq("ready ones first, by character: Ada", list[1].who, "Ada")
H.eq("...then Bronn, however long either has been ready", list[2].who, "Bronn")
H.eq("then the soonest: Merrily's Mooncloth in 2h", list[3].recipe, "Mooncloth")
H.eq("...then Bronn's in 5h", list[4].recipe, "Salt")
H.check("the character you are on is marked", list[3].you and not list[2].you)
H.eq("the class rides along for the colour", list[2].class, "WARRIOR")

-- ---------------------------------------------------------------------------
H.section("Ready text")
-- ---------------------------------------------------------------------------

H.eq("past", craft.ReadyText(NOW - 5, NOW), "ready now")
H.eq("now", craft.ReadyText(NOW, NOW), "ready now")
H.eq("a few seconds is a minute, never ready", craft.ReadyText(NOW + 5, NOW), "in 1m")
H.eq("minutes", craft.ReadyText(NOW + 14 * 60, NOW), "in 14m")
H.eq("an hour", craft.ReadyText(NOW + H1, NOW), "in 1h")
H.eq("hours and minutes, rounded up", craft.ReadyText(NOW + 2 * H1 + 13 * 60 + 1, NOW),
     "in 2h 14m")
H.eq("a day", craft.ReadyText(NOW + D1, NOW), "in 1d")
H.eq("days and hours", craft.ReadyText(NOW + D1 + 6 * H1, NOW), "in 1d 6h")

-- ---------------------------------------------------------------------------
H.section("The login line")
-- ---------------------------------------------------------------------------

H.isNil("nothing ready, nothing said",
        craft.ReminderText(craft.CooldownRows({ Merrily = chars.Merrily }, NOW), NOW))
H.eq("one", craft.ReminderText(craft.CooldownRows({ Ada = chars.Ada }, NOW), NOW),
     "1 profession cooldown is ready: Ada (Mooncloth)")
H.eq("several, named",
     craft.ReminderText(list, NOW),
     "2 profession cooldowns are ready: Ada (Mooncloth), Bronn (Transmute: Arcanite)")
local many = {}
for k = 1, 7 do
    many["Alt" .. k] = { recipes = { Mooncloth = { ready = NOW - k } } }
end
local line = craft.ReminderText(craft.CooldownRows(many, NOW), NOW)
H.check("past five it says how many more", line and string.find(line, " and 2 more", 1, true))
local named = 0
for _ in string.gfind(line or "", "%(Mooncloth%)") do named = named + 1 end
H.eq("...naming only five", named, 5)

-- ---------------------------------------------------------------------------
H.section("Forgetting, and the demo")
-- ---------------------------------------------------------------------------

local mine = db.MyCooldowns()
mine.recipes["Mooncloth"] = { ready = NOW }
H.check("forgetting a recipe takes it off", db.ForgetCooldown(db.CharKey(), "Mooncloth")
        and not mine.recipes["Mooncloth"])
H.check("...and forgetting it twice says so", not db.ForgetCooldown(db.CharKey(), "Mooncloth"))
H.check("off demo, the window reads the store", db.CooldownSource(NOW) == db.Cooldowns())
db.demo = true
local demo = db.CooldownSource(NOW)
H.check("in demo, it reads invented alts", demo ~= db.Cooldowns()
        and demo[db.DEMO_CHARS[1]] ~= nil)
local drows = craft.CooldownRows(demo, NOW)
local ready, soon, days = 0, 0, 0
for k = 1, table.getn(drows) do
    local left = drows[k].ready - NOW
    if left <= 0 then ready = ready + 1
    elseif left < D1 then soon = soon + 1
    else days = days + 1 end
end
H.check("the demo draws every state: ready, hours, days",
        ready > 0 and soon > 0 and days > 0)
H.isNil("...and wrote nothing to the store", db.Cooldowns()[db.DEMO_CHARS[1]])
db.demo = false

-- ---------------------------------------------------------------------------
H.section("The window and the events: ui/frame.lua")
-- ---------------------------------------------------------------------------

local f = assert(io.open("ui/frame.lua", "r"))
local src = f:read("*a")
f:close()
local function chunk(head)
    local at = assert(string.find(src, head, 1, true), "did not find: " .. head)
    local stop = assert(string.find(src, "\nend\n", at, true))
    return string.sub(src, at, stop + 4)
end
local function has(needle) return string.find(src, needle, 1, true) ~= nil end

ui = {}
_G.A = A
local said = {}
ChatMsg = function(t) table.insert(said, t) end
local function frameTick(fr) if fr:IsShown() then W.Tick(fr) end end

-- The capture wiring, from the dirty flag to the CHAT_MSG_LOOT handler.
do
    local at = assert(string.find(src, "function ui.MarkCooldownsDirty()", 1, true))
    local h = assert(string.find(src, 'A.RegisterEvent("CHAT_MSG_LOOT", function()\n'
        .. "    if A.craft and A.craft.ParseCreate", at, true))
    local stop = assert(string.find(src, "\nend)\n", h, true))
    local code = string.sub(src, at, stop + 5)
    -- ChatMsg is a file-scope local in frame.lua; the chunk reads the global.
    assert(loadstring(code))()
end
local repaints = 0
ui.RefreshCooldownWindow = function() repaints = repaints + 1 end
local reads = 0
local realRead = craft.ReadCooldownWindow
craft.ReadCooldownWindow = function(k) reads = reads + 1; return realRead(k) end

db.account.cdRecipes = {}
for k = 1, 30 do W.FireEvent(A.frame, "TRADE_SKILL_UPDATE") end
H.eq("thirty TRADE_SKILL_UPDATEs read nothing inline", reads, 0)
frameTick(ui.cdDriver)
H.eq("...and the window once, on the next frame", reads, 1)
frameTick(ui.cdDriver)
H.eq("...and not again until it fires again", reads, 1)
H.check("the driver idles once it has read", not ui.cdDriver:IsShown())
H.check("the read reached this character's record",
        db.MyCooldowns().recipes["Transmute: Arcanite"] ~= nil)
H.eq("...and the window was repainted", repaints, 1)
W.FireEvent(A.frame, "TRADE_SKILL_SHOW")
frameTick(ui.cdDriver)
H.eq("opening a profession window reads it", reads, 2)
-- A craft re-reads the window; it never starts a cooldown by itself.
W.FireEvent(A.frame, "CHAT_MSG_LOOT",
            "You create: |cffffffff|Hitem:3577:0:0:0|h[Gold Bar]|h|r.")
frameTick(ui.cdDriver)
H.eq("a craft re-reads the open window", reads, 3)
W.FireEvent(A.frame, "CHAT_MSG_LOOT", "You receive loot: Linen Cloth.")
frameTick(ui.cdDriver)
H.eq("any other loot line does nothing", reads, 3)
craft.ReadCooldownWindow = realRead

-- The login line, run for real: once per session.
assert(loadstring(chunk("function ui.CooldownLoginLine(")))()
do
    local at = assert(string.find(src, 'A.RegisterEvent("PLAYER_ENTERING_WORLD", function()\n'
        .. "    if ui.cdReminded then return end", 1, true))
    local stop = assert(string.find(src, "\nend)\n", at, true))
    assert(loadstring(string.sub(src, at, stop + 5)))()
end
local me2 = db.MyCooldowns()
me2.recipes = { ["Transmute: Arcanite"] = { ready = time() - 60, prof = "Alchemy" } }
said = {}
W.FireEvent(A.frame, "PLAYER_ENTERING_WORLD")
local saidLine = said[table.getn(said)]
H.check("at login, a ready cooldown is named",
        saidLine and string.find(saidLine, "(Transmute: Arcanite)", 1, true) ~= nil)
H.check("...pointing at /aex cd", saidLine and string.find(saidLine, "/aex cd", 1, true) ~= nil)
local before = table.getn(said)
W.FireEvent(A.frame, "PLAYER_ENTERING_WORLD")
H.eq("a second loading screen says nothing more", table.getn(said), before)
db.SetSetting("cdReminder", false)
H.isNil("with the reminder off, nothing", ui.CooldownLoginLine())
db.SetSetting("cdReminder", true)

H.check("/aex cd is the whole word",
        has('if string.find(cmd, "^%s*cd%s*$") then\n        ui.ToggleCooldownWindow()'))
H.check("the window keeps the wheel off your key bindings",
        has("    ui.cdFrame = f\n    ui.SwallowWheel(f)"))
H.check("forgetting asks first",
        has('StaticPopup_Show("AEGIS_EXCHANGE_FORGET_COOLDOWN", e.who, e.recipe)'))
H.check("...and never touches demo rows",
        has('if not e or arg1 ~= "RightButton" or A.db.demo then return end'))
H.check("the window reads demo data when it is on",
        has("local rows = A.craft.CooldownRows(A.db.CooldownSource(now), now,"))
H.check("the reminder box is the setting",
        has('A.db.SetSetting("cdReminder", remind:GetChecked() and true or false)'))

os.exit(H.report("cooldowns"))
