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

os.exit(H.report("purse"))
