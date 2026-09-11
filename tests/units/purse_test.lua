-- Aegis: Exchange -- tests/units/purse_test.lua
--
-- What every character on this realm is carrying in COIN, and what the account
-- had at any point in the past.
--
-- 1.12 HAS ONE MONEY CALL AND IT ANSWERS FOR YOU. `GetMoney()` is the
-- character you are logged in as and there is nothing that will tell you what
-- an alt has, so an account total is necessarily a sum of REMEMBERED figures,
-- each as fresh as the last time that character played. That is the same shape
-- Bagshui uses on this client -- read GetMoney on the money events, store it
-- per character, total across characters -- and the two places we differ are
-- deliberate:
--
--   * REALM-SCOPED, like the inventory block. Gold on a character you cannot
--     reach from here is not gold you can spend here.
--   * WE KEEP A HISTORY. "How much does this character have" needs one number;
--     "how much did the account have last Tuesday" cannot be recovered from
--     one number, and the chart asks the second question.
--
-- The failure modes worth guarding, all of which draw a plausible line:
--   * back-filling. A character with no sample before a bucket must contribute
--     NOTHING there, not its later figure -- otherwise gold appears in the past.
--   * forgetting to carry forward. An alt that has not played since Monday
--     holds Monday's figure across the rest of the week, because that is
--     genuinely what is known.
--   * an unbounded history. This is written from PLAYER_MONEY, which fires for
--     every copper.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)
local db = A.db
local HOUR, DAY = 3600, 86400

-- ---------------------------------------------------------------------------
H.section("recording what this character carries")
-- ---------------------------------------------------------------------------

W.player = "Torchlite"
local rec = db.SetCharMoney(120000, 10 * HOUR)
H.eq("the figure is stored", rec.now, 120000)
H.eq("...with the moment it was read", rec.t, 10 * HOUR)
H.eq("...and in its hour bucket", rec.hours[10], 120000)

-- A SECOND CHANGE IN THE SAME HOUR OVERWRITES IT. This is written from
-- PLAYER_MONEY, which fires for every copper earned, spent, looted or mailed --
-- one sample per transaction would grow without bound and tell the chart
-- nothing it cannot already see.
db.SetCharMoney(125000, 10 * HOUR + 900)
H.eq("the same hour is overwritten, not appended", rec.hours[10], 125000)
H.eq("...and only one key is held", table.getn(rec.keys), 1)
H.eq("the current figure follows", rec.now, 125000)

db.SetCharMoney(90000, 11 * HOUR)
H.eq("a new hour is a new sample", rec.hours[11], 90000)
H.eq("...and the old one survives", rec.hours[10], 125000)
H.eq("two keys now", table.getn(rec.keys), 2)

-- Garbage in.
H.isNil("a nil figure records nothing", db.SetCharMoney(nil, 12 * HOUR))
H.isNil("...nor a negative one", db.SetCharMoney(-5, 12 * HOUR))
H.eq("zero gold is a real answer and IS recorded",
     db.SetCharMoney(0, 12 * HOUR).hours[12], 0)

-- ---- the history is bounded ---------------------------------------------

-- TWO RESOLUTIONS IN ONE TABLE, which is how a three-month chart costs the
-- same SavedVariables as the old one-month one. Every sample starts hourly;
-- once it falls outside the fine window all but the day's LAST survive.
do
    W.player = "Hoarder"
    local last = db.MONEY_SAMPLES_MAX + 50
    local h = 1
    while h <= last do
        db.SetCharMoney(h, h * HOUR)
        h = h + 1
    end
    local hoarder = db.Purses()["Hoarder"]
    H.check("the sample list is thinned, not just capped",
            table.getn(hoarder.keys) < db.MONEY_SAMPLES_MAX,
            table.getn(hoarder.keys))

    -- FULL DETAIL INSIDE THE FINE WINDOW. The recent hours are the ones the
    -- 24h view draws, and thinning them would flatten it.
    local fine = 0
    local i = 1
    while i <= table.getn(hoarder.keys) do
        if hoarder.keys[i] > last - db.MONEY_FINE_HOURS then fine = fine + 1 end
        i = i + 1
    end
    H.eq("every hour inside the fine window survives",
         fine, db.MONEY_FINE_HOURS)

    -- ...and ONE A DAY outside it.
    --
    -- COMPACTED EXPLICITLY FIRST, because the real thing is AMORTISED: it runs
    -- only when the cap is exceeded, so between runs there is a tail of hourly
    -- samples that have aged out of the window and not yet been thinned. That
    -- is the whole point -- this is called from PLAYER_MONEY, which fires for
    -- every copper, and a walk on every write is the shape HARD RULE 16
    -- forbids. The rule is tested here; the amortisation is tested above.
    H.check("compaction drops something",
            db.CompactMoney(hoarder, last * HOUR) > 0)
    local days, twice = {}, nil
    i = 1
    while i <= table.getn(hoarder.keys) do
        local k = hoarder.keys[i]
        if k <= last - db.MONEY_FINE_HOURS then
            local d = db.MoneyDayOf(k)
            if days[d] then twice = d end
            days[d] = true
        end
        i = i + 1
    end
    H.isNil("no day outside the window keeps two samples", twice)

    -- ...and it is the day's CLOSING figure, because the series reader carries
    -- the last known value forward -- keeping the morning's would report it
    -- for the whole of the next day.
    local dayEnd = 24 * 3 - 1        -- hour 71, the last of day 2
    H.eq("the sample kept is the day's last", hoarder.hours[dayEnd], dayEnd)
    H.isNil("...and not one from earlier that day", hoarder.hours[dayEnd - 1])

    -- PRUNED FROM BOTH SIDES. Dropping the key and leaving the value behind is
    -- a table that grows forever while reporting that it does not.
    H.eq("the newest is always kept", hoarder.hours[last], last)

    -- The hard cap still exists behind the compaction, for a character played
    -- across more days than it allows.
    W.player = "Ancient"
    local d = 1
    while d <= db.MONEY_SAMPLES_MAX + 100 do
        db.SetCharMoney(d, d * 24 * HOUR)     -- one sample a day, for years
        d = d + 1
    end
    H.check("a history longer than the cap is still capped",
            table.getn(db.Purses()["Ancient"].keys) <= db.MONEY_SAMPLES_MAX,
            table.getn(db.Purses()["Ancient"].keys))
    H.isNil("...from the oldest end", db.Purses()["Ancient"].hours[24])
end

-- ---------------------------------------------------------------------------
H.section("the account total, across characters")
-- ---------------------------------------------------------------------------

W.Reset()
A = W.LoadCore()
W.FireAddonLoaded(A)
db = A.db

W.player = "Osiris"
db.SetCharMoney(300000, 100 * HOUR)
W.player = "Subtilizer"
db.SetCharMoney(50000, 120 * HOUR)
W.player = "Torchlite"
db.SetCharMoney(120000, 140 * HOUR)

local rows, total = db.PurseRows()
H.eq("every character is listed", table.getn(rows), 3)
H.eq("...and totalled", total, 470000)

-- THE CHARACTER YOU ARE ON IS READ LIVE. A stale figure where an exact one was
-- available is inexcusable, and it is the only one that can be exact.
rows, total = db.PurseRows(999)
local mine
for i = 1, table.getn(rows) do if rows[i].you then mine = rows[i] end end
H.eq("your own row is the live figure", mine.copper, 999)
H.eq("...and the total follows it", total, 300000 + 50000 + 999)
H.isNil("...carrying no age, because it was read now", mine.age)

-- ...and everyone else carries theirs.
local others = 0
for i = 1, table.getn(rows) do
    if not rows[i].you then
        H.check("an alt's figure is aged", rows[i].age ~= nil, rows[i].name)
        others = others + 1
    end
end
H.eq("two alts", others, 2)

-- YOU FIRST, then by size. The row you can act on is the one you are on.
H.eq("your row sorts first", rows[1].you, true)
H.check("...then the richest alt", rows[2].copper >= rows[3].copper,
        rows[2].copper .. " vs " .. rows[3].copper)

-- A FRESH CHARACTER STILL COUNTS. Nothing is stored until the money changes or
-- a loading screen ends, and without this the one figure that IS exact is the
-- one missing from the total.
W.player = "Newbie"
rows, total = db.PurseRows(7777)
H.eq("a character with nothing stored still gets a row", table.getn(rows), 4)
H.eq("...and is counted", total, 470000 + 7777)

-- ...and is not double-counted once it HAS been stored.
db.SetCharMoney(7777, 160 * HOUR)
rows, total = db.PurseRows(7777)
H.eq("stored and live is still one row", table.getn(rows), 4)
H.eq("...counted once", total, 470000 + 7777)

-- Per REALM, the same as the inventory block: gold on a character you cannot
-- reach from here is not gold you can spend here.
W.realm = "SomewhereElse"
db.realmKey = db.RealmKey()
local _, elsewhere = db.PurseRows()
H.eq("another realm has its own purses", elsewhere, 0)
W.realm = "TestRealm"
db.realmKey = db.RealmKey()
local _, back = db.PurseRows()
H.eq("...and going back finds them", back, 470000 + 7777)

-- ---------------------------------------------------------------------------
H.section("the account's coin OVER TIME")
-- ---------------------------------------------------------------------------

W.Reset()
A = W.LoadCore()
W.FireAddonLoaded(A)
db = A.db

-- Two characters. One plays early and stops; one plays late.
local T0 = 1000 * HOUR
W.player = "Early"
db.SetCharMoney(100, T0)
db.SetCharMoney(200, T0 + 1 * HOUR)
W.player = "Late"
db.SetCharMoney(50, T0 + 3 * HOUR)

-- Six hourly buckets covering T0-1h .. T0+5h.
local from, step, n = T0 - HOUR, HOUR, 6
local series = db.MoneySeries(from, step, n)
H.eq("one figure per bucket", table.getn(series), 6)

-- NOTHING IS BACK-FILLED. Before a character has any sample it contributes
-- nothing -- drawing its later figure into the past is gold that was not there.
H.eq("before anyone had been seen, the account had nothing", series[1], 0)

-- Bucket 2 ends at T0+1h, so Early's T0 sample of 100 is in it.
H.eq("the first sample lands", series[2], 100)
-- Bucket 3 ends at T0+2h and takes Early's newer figure.
H.eq("a newer sample replaces it, it does not add to it", series[3], 200)
-- Bucket 4 ends at T0+3h -- Late's sample is AT T0+3h, which is not before the
-- edge, so it has not landed yet.
H.eq("Early alone, carried forward", series[4], 200)
-- Bucket 5 ends at T0+4h and now holds both.
H.eq("both characters are summed", series[5], 250)

-- CARRIED FORWARD, NOT DROPPED. Early has not played since; the account still
-- has that gold, and a line that fell to Late's 50 would say it had been spent.
H.eq("a character who stopped playing still holds their figure",
     series[6], 250)

-- Degenerate input, because this runs on a fresh install with no samples at
-- all and inside a repaint.
H.eq("no buckets is an empty series", table.getn(db.MoneySeries(from, step, 0)), 0)
H.eq("a zero step is survivable",
     table.getn(db.MoneySeries(from, 0, 4)), 4)
H.eq("...and returns zeroes", db.MoneySeries(from, 0, 4)[1], 0)
H.eq("a nil origin is survivable",
     table.getn(db.MoneySeries(nil, step, 4)), 4)

-- ---- one character on their own -----------------------------------------

-- THE DROPDOWN PICKS WHOSE GOLD, so the series has to be able to answer for
-- one character rather than for the account.
do
    local one = db.MoneySeries(from, step, n, "Early")
    H.eq("a filtered series has the same shape", table.getn(one), 6)
    H.eq("...and only that character's figures", one[6], 200)
    local other = db.MoneySeries(from, step, n, "Late")
    H.eq("...and the other's are their own", other[6], 50)
    H.eq("the two add up to the account total", one[6] + other[6], series[6])
end

-- A CHARACTER WITH NO SAMPLES IN THE WINDOW is a real state and not the same
-- as one holding nothing: they exist, we have simply never seen them here.
-- Drawing them flat on the baseline says they are broke.
do
    local vals, seen = db.MoneySeries(from, step, n, "Early")
    H.eq("a character we have seen says so", seen, true)
    vals, seen = db.MoneySeries(from, step, n, "Nobody")
    H.eq("one we have not says so too", seen, false)
    H.eq("...and their series is still the right shape", table.getn(vals), 6)
    -- ...and the account-wide call answers it as well, for an install with
    -- nothing recorded at all.
    local _, anySeen = db.MoneySeries(from, step, n)
    H.eq("the account-wide call answers it too", anySeen, true)
end

-- ---- where "all time" starts --------------------------------------------

-- THE OLDEST SAMPLE, not the newest and not the epoch. A window starting at
-- the epoch is one flat line jammed against the right-hand edge; one starting
-- at the newest sample is a chart with nothing on it.
H.eq("the oldest sample is found", db.OldestMoney(), T0)
do
    W.player = "Earlier"
    db.SetCharMoney(1, T0 - 100 * HOUR)
    H.eq("...across every character", db.OldestMoney(), T0 - 100 * HOUR)
end

W.Reset()
A = W.LoadCore()
W.FireAddonLoaded(A)
db = A.db
H.isNil("nothing recorded has no oldest", db.OldestMoney())

-- ---------------------------------------------------------------------------
H.section("the money events actually write it")
-- ---------------------------------------------------------------------------

W.Reset()
A = W.LoadCore()
W.FireAddonLoaded(A)
db = A.db
W.player = "Torchlite"

W.money = 424242
W.FireEvent(A.frame, "PLAYER_MONEY")
local _, t = db.PurseRows()
H.eq("a money change is recorded", t, 424242)

-- PLAYER_MONEY ONLY FIRES WHEN THE FIGURE CHANGES, so a character you log in
-- on and do nothing with would never record what it is carrying. That is the
-- same gap that made the account-wide inventory read as "only shows the
-- character I am on" until v1.53.1.
W.Reset()
A = W.LoadCore()
W.FireAddonLoaded(A)
db = A.db
W.player = "Quiet"
W.money = 5150
W.FireEvent(A.frame, "PLAYER_ENTERING_WORLD")
local _, qt = db.PurseRows()
H.eq("arriving in the world records the purse", qt, 5150)

-- ---------------------------------------------------------------------------
H.section("the ledger knows who")
-- ---------------------------------------------------------------------------

W.Reset()
A = W.LoadCore()
W.FireAddonLoaded(A)
db = A.db

W.player = "Torchlite"
db.RecordTxn("sale", "Silk Cloth", 1000)
W.player = "Osiris"
db.RecordTxn("buy", "Linen Cloth", 400)
db.RecordTxn("sale", "Wool Cloth", 700)

local led = db.Ledger()
H.eq("an entry is stamped with the character", led[1].who, "Torchlite")
H.eq("...whoever recorded it", led[2].who, "Osiris")

local names, anon = db.LedgerByChar()
H.eq("both characters are found", table.getn(names), 2)
H.eq("...sorted", names[1], "Osiris")
H.eq("...and the second", names[2], "Torchlite")
H.eq("nothing was unattributed", anon, false)

-- HISTORY FROM BEFORE v1.53.7 CARRIES NO NAME and there is no way to recover
-- it. A reader has to be able to say "some of this is not attributable"
-- instead of quietly dropping it or pinning it on whoever is logged in.
table.insert(db.Ledger(), { t = time(), kind = "sale", item = "Old",
                            amount = 5 })
names, anon = db.LedgerByChar()
H.eq("an old entry adds no name", table.getn(names), 2)
H.eq("...but is reported as unattributed", anon, true)

-- The window applies, the same as it does to the totals beside it.
local now = time()
db.ClearLedger()
table.insert(db.Ledger(), { t = now - 40 * DAY, kind = "sale", item = "X",
                            amount = 5, who = "Ancient" })
table.insert(db.Ledger(), { t = now, kind = "sale", item = "Y",
                            amount = 5, who = "Recent" })
names = db.LedgerByChar(now - 7 * DAY)
H.eq("only characters inside the window", table.getn(names), 1)
H.eq("...the recent one", names[1], "Recent")

-- ---------------------------------------------------------------------------
H.section("demo data, and where it must never go")
-- ---------------------------------------------------------------------------

-- THE POINT OF THE MODE: the chart needs months of trading to look like
-- anything, and a new character has hours. Judging a layout against one
-- vertical spike is not judging it.
--
-- THE POINT OF ITS SHAPE: `db.demo` is a session flag and the generators are
-- consulted INSTEAD of the store, so there is no path by which invented gold
-- reaches a real save -- not by logging out, not by crashing, not by
-- forgetting it was on. That is what the first four checks are for.
W.Reset()
A = W.LoadCore()
W.FireAddonLoaded(A)
db = A.db
W.player = "Torchlite"

db.SetCharMoney(4242, 100 * HOUR)
local realRows, realTotal = db.PurseRows()
H.eq("the real purse is there to begin with", realTotal, 4242)

db.demo = true
local demoRows, demoTotal = db.PurseRows()
H.eq("demo mode lists the made-up characters",
     table.getn(demoRows), table.getn(db.DEMO_CHARS))
H.check("...with gold of their own", demoTotal > 0, demoTotal)
H.check("...which is not the real figure", demoTotal ~= realTotal, demoTotal)

-- NOTHING IS WRITTEN. The whole safety of this mode is that it substitutes a
-- reader; a seeded writer would have been half the code and permanently
-- dangerous.
-- ...AND THE SERIES, which is the half the chart actually draws. The rows are
-- only the picker's list; substituting one and not the other is a menu full of
-- made-up characters drawing the real (empty) line.
do
    local demoVals = db.MoneySeries(0, HOUR, 12)
    local moved = false
    local i = 2
    while i <= 12 do
        if demoVals[i] ~= demoVals[1] then moved = true end
        i = i + 1
    end
    H.check("demo mode draws a generated line, not the real one", moved)
    local one = db.MoneySeries(0, HOUR, 12, "Ashvane")
    H.check("...and can be filtered to one made-up character",
            one[12] > 0 and one[12] ~= demoVals[12], one[12])
end

db.demo = nil
do
    -- Back to the real thing: one character with a single sample, so the line
    -- is flat and unmistakably not generated.
    local realVals = db.MoneySeries(90 * HOUR, HOUR, 12)
    H.eq("turning it off draws the real line again", realVals[12], 4242)
end

local afterRows, afterTotal = db.PurseRows()
H.eq("turning it off restores the real purse", afterTotal, 4242)
H.eq("...with the real characters", table.getn(afterRows),
     table.getn(realRows))
do
    local stored = db.Purses()
    local n = 0
    for _ in pairs(stored) do n = n + 1 end
    H.eq("...and nothing was stored for the demo ones", n, 1)
    local k = 1
    while k <= table.getn(db.DEMO_CHARS) do
        H.isNil("no record for " .. db.DEMO_CHARS[k],
                stored[db.DEMO_CHARS[k]])
        k = k + 1
    end
end

-- ---- the generated shape -------------------------------------------------

-- DETERMINISTIC, because a chart that redraws differently every frame cannot
-- be looked at -- and because a generator that drifts makes every assertion
-- below meaningless.
do
    local a = db.DemoSeries(0, HOUR, 40, "Ashvane")
    local b = db.DemoSeries(0, HOUR, 40, "Ashvane")
    local same = true
    local i = 1
    while i <= 40 do
        if a[i] ~= b[i] then same = false end
        i = i + 1
    end
    H.check("the same window draws the same line twice", same)

    -- ...and two characters do NOT draw the same line, or the account view is
    -- one line multiplied.
    local c = db.DemoSeries(0, HOUR, 40, "Corvid")
    local differs = false
    i = 1
    while i <= 40 do
        if a[i] ~= c[i] then differs = true end
        i = i + 1
    end
    H.check("two characters draw different lines", differs)
end

-- GOLD HELD CANNOT BE NEGATIVE. A chart drawn from data its own reader could
-- not have produced is testing the wrong thing.
--
-- PER CHARACTER over a long run, not just the account total: four lines summed
-- can stay positive with one of them well below zero, so the total hides
-- exactly the fault this is looking for.
do
    local k = 1
    while k <= table.getn(db.DEMO_CHARS) do
        local one = db.DemoSeries(0, HOUR, 600, db.DEMO_CHARS[k])
        local worst = nil
        local i = 1
        while i <= 600 do
            if not worst or one[i] < worst then worst = one[i] end
            i = i + 1
        end
        H.check(db.DEMO_CHARS[k] .. " never goes below zero", worst >= 0, worst)
        k = k + 1
    end
end

do
    local vals = db.DemoSeries(0, HOUR, 200)
    H.eq("a bucket per request", table.getn(vals), 200)
    local worst, flat = nil, true
    local i = 1
    while i <= 200 do
        if not worst or vals[i] < worst then worst = vals[i] end
        if vals[i] ~= vals[1] then flat = false end
        i = i + 1
    end
    H.check("the account total is never negative either", worst >= 0, worst)
    -- ...and it MOVES. A flat line exercises none of what the mode exists for:
    -- the fill over a varying height, the axis at different magnitudes, the
    -- hover on a slope.
    H.check("the line actually moves", not flat)
end

-- The account view is the sum of the characters, the same as the real one.
do
    local total = db.DemoSeries(0, HOUR, 10)
    local sum = 0
    local k = 1
    while k <= table.getn(db.DEMO_CHARS) do
        sum = sum + db.DemoSeries(0, HOUR, 10, db.DEMO_CHARS[k])[10]
        k = k + 1
    end
    H.eq("all players is the sum of them", total[10], sum)
end

H.eq("no buckets is no series", table.getn(db.DemoSeries(0, HOUR, 0)), 0)

-- "All time" has to answer in demo mode too, or the window has no span and the
-- chart the demo exists to show falls back to a day.
db.demo = true
H.check("demo mode has an oldest sample", db.OldestMoney() ~= nil)
H.check("...well before now", db.OldestMoney() < time() - 86400)
db.demo = nil

-- The generator's own arithmetic. Lua 5.0 numbers are exact only to 2^53, and
-- the usual LCG multipliers overflow that against a 2^31 modulus -- which does
-- not error, it just quietly stops being random.
do
    local seed, wrapped = 1, true
    local i = 1
    while i <= 50 do
        seed = db.DemoNext(seed)
        if seed < 0 or seed >= 2147483647 then wrapped = false end
        if seed ~= math.floor(seed) then wrapped = false end
        i = i + 1
    end
    H.check("the generator stays a whole number in range", wrapped, seed)

    -- THE MULTIPLY HAS TO STAY EXACT, and this checks the arithmetic rather
    -- than its symptoms. Lua 5.0 numbers are doubles, exact only to 2^53; the
    -- usual LCG multipliers (1103515245 and friends) reach ~2.4e18 against a
    -- 2^31 modulus and quietly stop being arithmetic.
    --
    -- Tried first as a behavioural test -- "does any draw come back odd" --
    -- and that PASSED with the overflowing multiplier, because a float that
    -- has lost its low bits still lands on odd numbers after a modulo. The
    -- property worth asserting is the bound itself.
    H.check("the generator's multiply stays inside 2^53",
            (db.DEMO_MOD - 1) * db.DEMO_MULT < 9007199254740992,
            db.DEMO_MOD .. " x " .. db.DEMO_MULT)
    H.check("a name seeds it", db.DemoSeed("Ashvane") > 0)
    H.check("...differently from another name",
            db.DemoSeed("Ashvane") ~= db.DemoSeed("Corvid"))
    -- Position-weighted, so two names that are anagrams do not draw the same
    -- line.
    H.check("...and from its own anagram",
            db.DemoSeed("Corvid") ~= db.DemoSeed("Divroc"))
end

-- ---------------------------------------------------------------------------
H.section("demo mode reaches the Crafting tab too")
-- ---------------------------------------------------------------------------

-- SAME DISCIPLINE AS THE GOLD: consulted instead of the store, never written
-- to it. A recipe list is the other half of what the demo is for -- the
-- shopping list and the crafting tree have nothing to draw on a fresh install
-- either.
do
    local craft = A.craft
    W.Reset()
    A = W.LoadCore()
    W.FireAddonLoaded(A)
    db, craft = A.db, A.craft

    H.eq("no recipes to begin with", table.getn(craft.Projects()), 0)

    db.demo = true
    local demo = craft.Projects()
    H.check("demo mode has recipes", table.getn(demo) > 0, table.getn(demo))
    H.eq("...the ones it defines",
         table.getn(demo), table.getn(craft.DEMO_PROJECTS))

    db.demo = nil
    H.eq("turning it off puts them away", table.getn(craft.Projects()), 0)

    -- NOTHING IS WRITTEN. The store is the same as it was.
    craft.AddProject({ name = "Real Thing", itemId = 1, reagents = {} })
    H.eq("a real recipe is still the only stored one",
         table.getn(craft.Projects()), 1)
    db.demo = true
    H.check("...and demo mode does not add to it",
            table.getn(craft.Projects()) == table.getn(craft.DEMO_PROJECTS))
    db.demo = nil
    H.eq("...nor take from it", craft.Projects()[1].name, "Real Thing")

    -- ---- the shape of the generated recipes -----------------------------

    -- EVERY ONE IS COMPLETE, or the shopping list divides by a nil somewhere.
    local i = 1
    while i <= table.getn(craft.DEMO_PROJECTS) do
        local p = craft.DEMO_PROJECTS[i]
        H.check("demo recipe " .. i .. " is named",
                p.name and p.name ~= "", tostring(p.name))
        H.check("...has an item id", p.itemId ~= nil, p.name)
        H.check("...wants a real number", (p.want or 0) >= 1, p.name)
        H.check("...and has reagents", table.getn(p.reagents or {}) > 0, p.name)
        local r = 1
        while r <= table.getn(p.reagents) do
            local g = p.reagents[r]
            H.check(p.name .. " reagent " .. r .. " is named",
                    g.name and g.name ~= "")
            H.check("...has an id", g.itemId ~= nil, g.name)
            H.check("...and a count", (g.count or 0) >= 1, g.name)
            r = r + 1
        end
        i = i + 1
    end

    -- CHOSEN TO EXERCISE THE LIST, not just to fill it. One of the recipes is
    -- also a REAGENT of another, which is the sub-reagent expansion -- without
    -- it the demo never reaches the branch that turns "short of a Bolt" into
    -- "buy the Linen Cloth to make one".
    do
        local made = {}
        local k = 1
        while k <= table.getn(craft.DEMO_PROJECTS) do
            made[craft.DEMO_PROJECTS[k].itemId] = true
            k = k + 1
        end
        local nested = false
        k = 1
        while k <= table.getn(craft.DEMO_PROJECTS) do
            local rs = craft.DEMO_PROJECTS[k].reagents
            local r = 1
            while r <= table.getn(rs) do
                if made[rs[r].itemId] then nested = true end
                r = r + 1
            end
            k = k + 1
        end
        H.check("one demo recipe is a reagent of another", nested,
                "without it the sub-reagent expansion is never exercised")
    end

    -- SOME OF EACH, NOT ALL AND NOT NONE. A list where every line reads 0 / 12
    -- has no progress on it, and the "12 / 42" a reagent row exists to show is
    -- the thing worth looking at.
    do
        -- ASKED OF THE RECIPES, not of the table. Counting entries in
        -- DEMO_HAVE only proves the table is not empty -- it stays green with
        -- every id in it pointing at something no recipe wants, which is a
        -- demo where every line still reads 0 / n.
        local anyGathered = false
        local k = 1
        while k <= table.getn(craft.DEMO_PROJECTS) do
            local rs = craft.DEMO_PROJECTS[k].reagents
            local r = 1
            while r <= table.getn(rs) do
                if (craft.DEMO_HAVE[rs[r].itemId] or 0) > 0 then
                    anyGathered = true
                end
                r = r + 1
            end
            k = k + 1
        end
        H.check("a reagent the recipes actually want is part-gathered",
                anyGathered,
                "counting DEMO_HAVE's own entries proves nothing about them")
        local allCovered = true
        local k = 1
        while k <= table.getn(craft.DEMO_PROJECTS) do
            local rs = craft.DEMO_PROJECTS[k].reagents
            local r = 1
            while r <= table.getn(rs) do
                if not craft.DEMO_HAVE[rs[r].itemId] then allCovered = false end
                r = r + 1
            end
            k = k + 1
        end
        H.check("...but not all of them, so there is something to buy",
                not allCovered)
    end

    -- ---- the spread of qualities ----------------------------------------

    -- THE WHOLE REASON THIS SET REPLACED THE LAST ONE. The first demo was
    -- four linen-and-mithril recipes and every item in it was white, so the
    -- quality colouring the shopping panel had just gained had nothing to
    -- colour -- a feature demonstrated by a demo in which it is invisible.
    --
    -- THE EXPECTED QUALITIES LIVE HERE, NOT IN THE ADDON, because the addon
    -- has no business carrying a copy of a fact the client already holds --
    -- ui.CraftQualityOf asks GetItemInfo and that answer is the one a player
    -- sees. This table is the VERIFICATION: every id below was checked
    -- against a vanilla item dump rather than remembered, which matters more
    -- than it sounds -- Black Lotus and Arcanite Reaper both FEEL epic and
    -- neither is, and an earlier draft of this set was picked from memory and
    -- would have been wrong about both.
    --
    --   1 Common   2 Uncommon   3 Rare   4 Epic
    local QUALITY = {
        [17193] = 4,   -- Sulfuron Hammer
        [12784] = 3,   -- Arcanite Reaper
        [16984] = 4,   -- Black Dragonscale Boots
        [12360] = 2,   -- Arcanite Bar          (product AND reagent)
        [17203] = 4,   -- Sulfuron Ingot
        [17011] = 3,   -- Lava Core
        [17010] = 3,   -- Fiery Core
        [7078]  = 2,   -- Essence of Fire
        [11382] = 2,   -- Blood of the Mountain
        [12363] = 2,   -- Arcane Crystal
        [11371] = 1,   -- Dark Iron Bar
        [12359] = 1,   -- Thorium Bar
        [12810] = 1,   -- Enchanted Leather
        [12644] = 1,   -- Dense Grinding Stone
        [15416] = 1,   -- Black Dragonscale
        [14341] = 1,   -- Rune Thread
    }

    do
        local prodQ, reagQ, unknown = {}, {}, {}
        local k = 1
        while k <= table.getn(craft.DEMO_PROJECTS) do
            local p = craft.DEMO_PROJECTS[k]
            local q = QUALITY[p.itemId]
            if q then prodQ[q] = true else table.insert(unknown, p.name) end
            local rs, r = p.reagents, 1
            while r <= table.getn(rs) do
                local rq = QUALITY[rs[r].itemId]
                if rq then reagQ[rq] = true
                else table.insert(unknown, rs[r].name) end
                r = r + 1
            end
            k = k + 1
        end

        -- EVERY id accounted for, or the two checks below are passing on a
        -- subset: add a recipe whose quality nobody looked up and the spread
        -- still reads epic-and-rare off the OTHER entries.
        H.eq("every demo item's quality was verified",
             table.concat(unknown, ", "), "")

        H.check("a demo recipe is EPIC", prodQ[4],
                "no epic recipe -- purple has nothing to colour")
        H.check("...and one is RARE", prodQ[3],
                "no rare recipe -- blue has nothing to colour")
        H.check("a demo REAGENT is epic", reagQ[4],
                "epic only ever appears on the recipe line")
        H.check("...and one is rare", reagQ[3],
                "rare only ever appears on the recipe line")
        -- ...and the plain ones too, or there is no contrast to see it
        -- against and every line is the same colour again, just a louder one.
        H.check("common reagents are still in the mix", reagQ[1])
        H.check("...and uncommon ones", reagQ[2])
    end

    -- ---- the prices the money columns read ------------------------------

    -- WITHOUT THESE EVERY MONEY FIGURE ON THE TAB IS A DASH, and a demo whose
    -- entire purpose is letting a layout be judged cannot show the money
    -- columns empty. The real price DB is untouched -- same substitution as
    -- the gold series.
    do
        local missing = {}
        local k = 1
        while k <= table.getn(craft.DEMO_PROJECTS) do
            local p = craft.DEMO_PROJECTS[k]
            if not craft.DEMO_PRICE[p.itemId] then
                table.insert(missing, p.name)
            end
            local rs, r = p.reagents, 1
            while r <= table.getn(rs) do
                if not craft.DEMO_PRICE[rs[r].itemId] then
                    table.insert(missing, rs[r].name)
                end
                r = r + 1
            end
            k = k + 1
        end
        H.eq("every demo item has a demo price",
             table.concat(missing, ", "), "")
    end

    -- THE VENDOR BRANCH. craft.CheaperSource picks the cheaper of vendor and
    -- auction house per line, and a demo with no vendor price never reaches
    -- it -- every line reads "ah" and the source column is a column of one
    -- value. The vendor entry has to be the CHEAPER of the two or the branch
    -- is reached and still never taken.
    do
        local any = false
        for id, v in pairs(craft.DEMO_VENDOR) do
            local ah = craft.DEMO_PRICE[id]
            H.check("demo vendor item " .. id .. " also has an AH price",
                    ah ~= nil, "CheaperSource needs both to compare")
            if ah and v < ah then any = true end
        end
        H.check("a demo line is cheaper at the vendor than at the AH", any,
                "the vendor branch is reachable but never taken")

        -- ...and it is a reagent something actually wants, or the line never
        -- appears on the list at all.
        local wanted = false
        local k = 1
        while k <= table.getn(craft.DEMO_PROJECTS) do
            local rs, r = craft.DEMO_PROJECTS[k].reagents, 1
            while r <= table.getn(rs) do
                if craft.DEMO_VENDOR[rs[r].itemId] then wanted = true end
                r = r + 1
            end
            k = k + 1
        end
        H.check("...and a recipe wants it", wanted)
    end

    -- ---- craft.MarketUnit / craft.VendorUnit ----------------------------

    -- ONE SOURCE FOR BOTH READERS. The tab's totals go through craft.CostOf
    -- and the shopping list prices its rows through an injected `marketOf`;
    -- when those were two copies of "min buyout, else market value" the
    -- panel's total could stop agreeing with the lines above it. This is also
    -- the one seam demo mode substitutes at.
    do
        db.demo = true
        H.eq("demo mode answers from the demo table",
             craft.MarketUnit(17203), craft.DEMO_PRICE[17203])
        H.isNil("...and says nothing for an item it has no price for",
                craft.MarketUnit(99999))
        H.isNil("no item id, no price", craft.MarketUnit(nil))
        H.eq("the vendor price comes from the demo table too",
             craft.VendorUnit(14341), craft.DEMO_VENDOR[14341])
        H.isNil("...and nothing for an item no merchant stocks",
                craft.VendorUnit(17203))

        -- AND THE REAL VENDOR RECORD IS NOT CONSULTED EITHER. Asking for an
        -- item the demo has no vendor entry for must be nil BECAUSE demo mode
        -- stopped there -- not because the merchant DB happened to be empty
        -- too. A harvested price is planted first so the two reasons are
        -- distinguishable.
        db.SetVendorBuy(17203, 777)
        H.isNil("a harvested vendor price does not leak into demo mode",
                craft.VendorUnit(17203))
        db.demo = nil
        H.eq("...and with demo off it is the answer",
             craft.VendorUnit(17203), 777)
        db.demo = true

        -- THE REAL DB IS NOT CONSULTED while demo is on. Recording a real
        -- price for an item the demo table does not carry must still read as
        -- no price -- otherwise the demo is a mix of invented and real
        -- numbers, which is the one thing a demo may not be.
        db.RecordAuction(99999, 4242)
        H.isNil("a real recorded price does not leak into demo mode",
                craft.MarketUnit(99999))

        db.demo = nil
        H.eq("with demo off the real price is the answer",
             craft.MarketUnit(99999), 4242)
        H.isNil("...and the demo price is not",
                craft.MarketUnit(17203))
    end

    -- ZERO IS NOT A PRICE. An item recorded at nothing is an item we have not
    -- really seen, and letting a zero through makes a cost total that reads
    -- COMPLETE when it is not -- a crafting cost that reads low, which is the
    -- direction that loses money.
    --
    -- PLANTED STRAIGHT INTO THE STORE, not put there with db.RecordAuction,
    -- which refuses `unitBuyout <= 0` at its own door. Going through the
    -- front door records NOTHING, so MarketUnit answers nil because the item
    -- was never seen -- and the check passes without ever reaching the guard
    -- it claims to be about. That was the first draft of this block.
    do
        db.demo = nil
        local items = db.Items()
        items[99998] = { daily = { [db.Day()] = 0 }, seen = 3 }
        H.eq("...and the zero really is in the store",
             db.MinBuyout(99998), 0)
        H.isNil("a zero price is no price", craft.MarketUnit(99998))

        -- ...and the fallback may not rescue it either: a weighted median of
        -- nothing but zeros is zero, so BOTH guards have to hold.
        H.eq("the market-value fallback also sees the zero",
             db.MarketValue(99998), 0)
    end

    -- ...AND THE FALLBACK IS NOT DEAD CODE, which is the only interesting
    -- question about it. db.MinBuyout answers whenever db.MarketValue does --
    -- both read the same `daily` table -- so "min buyout missing, market
    -- value present" cannot happen and a test built on that case would prove
    -- nothing. The case that DOES happen is the newest day recorded as a bogus
    -- zero over a run of real older days: MinBuyout reads the newest and
    -- returns 0, the guard above rejects it, and the weighted median over the
    -- whole window is what rescues the line.
    do
        db.demo = nil
        local today = db.Day()
        local items = db.Items()
        items[99997] = { seen = 9, daily = {
            [today] = 0, [today - 1] = 5000, [today - 2] = 5000,
        } }
        H.eq("the newest day is the bogus zero", db.MinBuyout(99997), 0)
        H.check("...but the window as a whole is not",
                db.MarketValue(99997) > 0, db.MarketValue(99997))
        H.eq("so the fallback answers", craft.MarketUnit(99997),
             db.MarketValue(99997))
    end
end

os.exit(H.report("purse"))
