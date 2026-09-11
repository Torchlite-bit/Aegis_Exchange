-- Aegis: Exchange -- tests/units/inventory_test.lua
--
-- "How many of these do I own, and where."
--
-- THE THING THAT MAKES THIS HARD is not the counting. It is that only ONE of
-- the four places can be read on demand:
--
--   bags   live -- containers 0..4 answer whenever you ask
--   bank   containers -1 and 5..10 answer ONLY while the bank frame is open
--   ah     your own auctions answer only while the auction house is open
--   mail   attachments answer only at the mailbox
--
-- So three of the four are memories of a visit, and a memory presented as a
-- fact is how a player walks to the bank for something that is not there. Every
-- number that is not live carries its age, and the tooltip says so in one line.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)
local db, sell = A.db, A.sell

W.AddItem(4306, { name = "Silk Cloth", quality = 1 })
W.AddItem(2589, { name = "Linen Cloth", quality = 1 })
local SILK, LINEN = W.items[4306].link, W.items[2589].link

-- ---------------------------------------------------------------------------
H.section("counting containers")
-- ---------------------------------------------------------------------------

W.SetBags({
    [0] = { { link = SILK, count = 12 }, { link = LINEN, count = 4 }, {} },
    [1] = { { link = SILK, count = 8 } },
})
local counts = sell.CountContainers(sell.BAG_CONTAINERS)
H.eq("stacks of one item across bags are summed", counts[4306], 20)
H.eq("...and another item is kept separate", counts[2589], 4)
H.isNil("an item you do not have is absent", counts[99999])

-- The bank is a DIFFERENT set of containers, and -1 is one of them. A walker
-- that assumed 0..4 would silently count nothing and report an empty bank,
-- which reads exactly like "you have none there".
H.eq("the bank walks seven containers",
     table.getn(sell.BANK_CONTAINERS), 7)
H.eq("...starting at BANK_CONTAINER", sell.BANK_CONTAINERS[1], -1)

W.SetBags({
    [0] = { { link = SILK, count = 12 } },
    [-1] = { { link = SILK, count = 30 } },
    [5]  = { { link = SILK, count = 5 }, { link = LINEN, count = 2 } },
})
local bank = sell.CountContainers(sell.BANK_CONTAINERS)
H.eq("the bank's own slots and its bags are summed", bank[4306], 35)
H.eq("...and the bags are NOT in it", bank[4306], 35)
H.eq("other bank items too", bank[2589], 2)

-- ---------------------------------------------------------------------------
H.section("bag counts are rebuilt only when the bags change")
-- ---------------------------------------------------------------------------

-- HARD RULE 16. BAG_UPDATE storms -- the client fires it repeatedly while item
-- data resolves, and the stock MAIL_SHOW handler calls OpenBackpack(), so a
-- mailbox with unseen attachments sets it off. The handler may only set a
-- flag; the walk happens when someone asks.
W.SetBags({ [0] = { { link = SILK, count = 7 } } })
sell.bagsDirty = true
H.eq("the first read walks the bags", sell.BagCounts()[4306], 7)

-- Change the bags WITHOUT telling it. A cached answer is the point.
W.SetBags({ [0] = { { link = SILK, count = 999 } } })
H.eq("a second read does not walk again", sell.BagCounts()[4306], 7)

W.FireEvent(A.frame, "BAG_UPDATE")
H.eq("BAG_UPDATE marks it dirty", sell.bagsDirty, true)
H.eq("...and the next read picks the change up", sell.BagCounts()[4306], 999)
H.eq("...and clears the flag", sell.bagsDirty, false)

-- ---------------------------------------------------------------------------
H.section("a fresh character still sees their own bags")
-- ---------------------------------------------------------------------------

-- THE COMMON CASE ON A FRESH INSTALL, and it had no row at all. Nothing is
-- stored for a character until they open a bank, so the reader found nobody
-- and their own bags -- the one bucket that is exact and always available --
-- were invisible. It presented as the block simply never appearing.
W.Reset()
A = W.LoadCore()
W.FireAddonLoaded(A)
db, sell = A.db, A.sell
W.AddItem(4306, { name = "Silk Cloth", quality = 1 })
SILK = W.items[4306].link

W.SetBags({ [0] = { { link = SILK, count = 9 } } })
sell.bagsDirty = true
local fresh, freshTotal = db.InventoryRows(4306, sell.BagCounts())
H.eq("a character with nothing stored still gets a row",
     table.getn(fresh), 1)
H.eq("...counting their live bags", fresh[1].bags, 9)
H.eq("...and the total", freshTotal, 9)
H.eq("...marked as you", fresh[1].you, true)

-- ...and it does not invent a row for an item they do not carry.
H.eq("no row for something they do not have",
     table.getn(db.InventoryRows(2589, sell.BagCounts())), 0)

-- ---------------------------------------------------------------------------
H.section("the bank is snapshotted when it opens")
-- ---------------------------------------------------------------------------

W.SetBags({
    [0]  = { { link = SILK, count = 3 } },
    [-1] = { { link = SILK, count = 25 } },
})
W.FireEvent(A.frame, "BANKFRAME_OPENED")

local rows, total = db.InventoryRows(4306, sell.BagCounts())
H.eq("one character holds it", table.getn(rows), 1)
H.eq("the total spans both places", total, 28)
H.eq("bags", rows[1].bags, 3)
H.eq("bank", rows[1].bank, 25)
H.eq("nothing at auction", rows[1].ah, 0)
H.eq("nothing in the post", rows[1].mail, 0)
H.eq("it is you", rows[1].you, true)
H.eq("...and your class was recorded", rows[1].class, "MAGE")

-- ---------------------------------------------------------------------------
H.section("live bags beat the snapshot, and only for you")
-- ---------------------------------------------------------------------------

-- The bank visit above stored a bag snapshot too. Move items now: the row must
-- follow the LIVE bags, because that is the one bucket that can be exact and
-- a stale number where an exact one was available is inexcusable.
W.SetBags({ [0] = { { link = SILK, count = 60 } }, [-1] = {} })
sell.bagsDirty = true
rows, total = db.InventoryRows(4306, sell.BagCounts())
H.eq("your bags are read live", rows[1].bags, 60)
H.eq("...while the bank stays as it was last seen", rows[1].bank, 25)
H.eq("...and the total follows", total, 85)

-- Without live bags handed in, it falls back to the stored snapshot rather
-- than reporting nothing.
rows = db.InventoryRows(4306, nil)
H.eq("no live bags, the snapshot answers", rows[1].bags, 3)

-- ---------------------------------------------------------------------------
H.section("freshness")
-- ---------------------------------------------------------------------------

-- A bucket that contributed a count carries its age; live bags do not.
rows = db.InventoryRows(4306, sell.BagCounts())
H.check("the bank count is aged", rows[1].oldest ~= nil)

W.now = W.now + 172800          -- two days later
rows = db.InventoryRows(4306, sell.BagCounts())
H.check("...and the age grows", rows[1].oldest >= 172800,
        tostring(rows[1].oldest))

-- An item held ONLY in live bags has no age at all, so the tooltip's
-- "as of your last visit" line does not appear for it.
W.SetBags({ [0] = { { link = LINEN, count = 5 } } })
sell.bagsDirty = true
local lrows = db.InventoryRows(2589, sell.BagCounts())
H.eq("a bags-only holding is found", lrows[1].bags, 5)
H.isNil("...and carries no age", lrows[1].oldest)

-- ---------------------------------------------------------------------------
H.section("characters with none of it are left out")
-- ---------------------------------------------------------------------------

-- A tooltip listing every alt you have ever logged in on, most of them saying
-- zero, is a worse answer than a short list.
H.eq("an item nobody holds gives no rows",
     table.getn(db.InventoryRows(99999, sell.BagCounts())), 0)
local _, zeroTotal = db.InventoryRows(99999, sell.BagCounts())
H.eq("...and a zero total", zeroTotal, 0)
H.eq("a nil id is handled",
     table.getn(db.InventoryRows(nil, nil)), 0)

-- ---------------------------------------------------------------------------
H.section("inventory is per REALM")
-- ---------------------------------------------------------------------------

-- The opposite of vendor prices, deliberately. A vendor's price is a fact
-- about the game and is the same everywhere; twenty Silk Cloth on a character
-- you cannot reach from here is not stock you have.
H.check("this realm sees it", table.getn(db.InventoryRows(4306, nil)) > 0)
W.realm = "SomewhereElse"
db.realmKey = db.RealmKey()
H.eq("another realm sees none of it",
     table.getn(db.InventoryRows(4306, nil)), 0)
W.realm = "TestRealm"
db.realmKey = db.RealmKey()
H.check("...and going back finds it again",
        table.getn(db.InventoryRows(4306, nil)) > 0)

-- ---------------------------------------------------------------------------
H.section("what is at auction -- a sweep, because the client holds one page")
-- ---------------------------------------------------------------------------

W.Reset()
A = W.LoadCore()
W.FireAddonLoaded(A)
db, sell = A.db, A.sell
W.AddItem(4306, { name = "Silk Cloth", quality = 1 })
W.AddItem(2589, { name = "Linen Cloth", quality = 1 })
SILK = W.items[4306].link
local LINEN2 = W.items[2589].link

local function owned(n, link, name, count)
    local rows = {}
    for i = 1, n do
        rows[i] = { name = name, count = count or 1, buyout = 100,
                    minBid = 50, quality = 1, level = 1, link = link }
    end
    return rows
end

-- More than one page, which is the case the sweep exists for: the client
-- holds fifty at a time and a book bigger than that cannot be counted from
-- whatever page happens to be loaded.
local book = owned(50, SILK, "Silk Cloth", 2)
local more = owned(20, LINEN2, "Linen Cloth", 3)
local all = {}
for i = 1, 50 do all[i] = book[i] end
for i = 1, 20 do all[50 + i] = more[i] end
W.SetOwned(all)

W.FireEvent(A.frame, "AUCTION_HOUSE_SHOW")
H.check("a sweep started", sell.ownerSweep ~= nil)
-- Each request answers with AUCTION_OWNED_LIST_UPDATE; drive it the way the
-- client does until the sweep is done.
local guard = 0
while sell.ownerSweep and guard < 10 do
    W.FireEvent(A.frame, "AUCTION_OWNED_LIST_UPDATE")
    guard = guard + 1
end
H.isNil("the sweep finished", sell.ownerSweep)

local arows = db.InventoryRows(4306, nil)
H.eq("stacks at auction are counted, not auctions", arows[1].ah, 100)
local lrows2 = db.InventoryRows(2589, nil)
H.eq("...across every page", lrows2[1].ah, 60)

-- Cancelling your last auction has to be RECORDED, or the old count sits on
-- the tooltip until you post again.
W.SetOwned({})
W.FireEvent(A.frame, "AUCTION_HOUSE_SHOW")
guard = 0
while sell.ownerSweep and guard < 10 do
    W.FireEvent(A.frame, "AUCTION_OWNED_LIST_UPDATE"); guard = guard + 1
end
H.eq("an empty book clears the count",
     table.getn(db.InventoryRows(4306, nil)), 0)

-- ---------------------------------------------------------------------------
H.section("...and the sweep yields to the player")
-- ---------------------------------------------------------------------------

-- Two things driving GetOwnerAuctionItems would fight over the one page the
-- client holds. The player's click wins; ours is bookkeeping.
W.SetOwned(all)
W.FireEvent(A.frame, "AUCTION_HOUSE_SHOW")
H.check("a sweep is running", sell.ownerSweep ~= nil)
sell.CancelOwnerSweep()
H.isNil("cancelling stops it", sell.ownerSweep)
H.eq("...and a stray page update does nothing", sell.OwnerSweepStep(), false)

-- Walking away stops it too, rather than leaving it armed for next time.
W.FireEvent(A.frame, "AUCTION_HOUSE_SHOW")
H.check("a sweep is running again", sell.ownerSweep ~= nil)
W.FireEvent(A.frame, "AUCTION_HOUSE_CLOSED")
H.isNil("closing the auction house cancels it", sell.ownerSweep)

-- ---------------------------------------------------------------------------
H.section("what is in the post")
-- ---------------------------------------------------------------------------

W.Reset()
A = W.LoadCore()
W.FireAddonLoaded(A)
db, sell = A.db, A.sell
W.AddItem(4306, { name = "Silk Cloth", quality = 1 })

-- 1.12 has no GetInboxItemLink, so mail resolves BY NAME through the map the
-- scanner fills. An item that map has never seen cannot be identified at all.
db.RecordAuction(4306, 500, "Silk Cloth")
W.SetInbox({
    { name = "Silk Cloth", count = 12 },
    { name = "Silk Cloth", count = 8 },
    { name = "Something Never Scanned", count = 5 },
})

-- HARD RULE 16: the handler may only set a flag. MAIL_INBOX_UPDATE is the
-- storm event -- dozens of fires in a few frames while attachments resolve --
-- and the read is per attachment.
W.FireEvent(A.frame, "MAIL_INBOX_UPDATE")
H.eq("the handler only marks it dirty", sell.mailDirty, true)
H.eq("...and records nothing yet",
     table.getn(db.InventoryRows(4306, nil)), 0)

-- The driver does the work, once.
W.Tick(sell.invDriver, 0.1)
H.eq("the flush clears the flag", sell.mailDirty, false)
local mrows = db.InventoryRows(4306, nil)
H.eq("mail is counted, stacks summed", mrows[1].mail, 20)

-- A storm of fires is still one flush.
W.FireEvent(A.frame, "MAIL_INBOX_UPDATE")
W.FireEvent(A.frame, "MAIL_INBOX_UPDATE")
W.FireEvent(A.frame, "MAIL_INBOX_UPDATE")
H.eq("still just a flag", sell.mailDirty, true)
W.Tick(sell.invDriver, 0.1)
H.eq("one flush clears it", sell.mailDirty, false)
H.eq("...and the driver stops running itself",
     sell.invDriver.shown, false)

-- An item the name map has never seen is skipped rather than guessed at.
local counts = sell.MailCounts()
local seen = 0
for _ in pairs(counts) do seen = seen + 1 end
H.eq("only the item we can identify is counted", seen, 1)

-- ---------------------------------------------------------------------------
H.section("the whole account, not just the character you are on")
-- ---------------------------------------------------------------------------

W.Reset()
A = W.LoadCore()
W.FireAddonLoaded(A)
db, sell = A.db, A.sell
W.AddItem(4306, { name = "Silk Cloth", quality = 1 })
SILK = W.items[4306].link

-- Play three characters in turn, each leaving a snapshot behind. Nothing on
-- 1.12 can read another character's inventory, so this -- one write per
-- character while it is logged in -- is the only route there is.
local function playAs(name, class, bags, bank)
    W.player, W.class = name, class
    W.SetBags(bags)
    sell.bagsDirty = true
    if bank then
        local merged = {}
        for k, v in pairs(bags) do merged[k] = v end
        for k, v in pairs(bank) do merged[k] = v end
        W.SetBags(merged)
        sell.bagsDirty = true
        W.FireEvent(A.frame, "BANKFRAME_OPENED")
    else
        sell.SnapshotBags()
    end
end

playAs("Torchlight", "MAGE",
       { [0] = { { link = SILK, count = 3 } } },
       { [-1] = { { link = SILK, count = 5 } } })
playAs("Subtilizer", "ROGUE",
       { [0] = { { link = SILK, count = 10 } } },
       { [-1] = { { link = SILK, count = 9 } } })
playAs("Torchlite", "DRUID",
       { [0] = { { link = SILK, count = 1 } } }, nil)

-- Back on the first one, hovering the item.
W.player, W.class = "Torchlight", "MAGE"
W.SetBags({ [0] = { { link = SILK, count = 3 } },
            [-1] = { { link = SILK, count = 5 } } })
sell.bagsDirty = true

local accRows, accTotal = db.InventoryRows(4306, sell.BagCounts())
H.eq("all three characters appear", table.getn(accRows), 3)
H.eq("...and the total spans them", accTotal, 3 + 5 + 10 + 9 + 1)

-- YOU come first. Your row is the one you are acting on; the rest are context.
H.eq("the character you are on leads", accRows[1].name, "Torchlight")
H.eq("...and is marked as you", accRows[1].you, true)
H.eq("...the rest are not", accRows[2].you, false)

-- ...then the biggest holdings, so a glance finds where the stock actually is.
H.eq("then the largest holding", accRows[2].name, "Subtilizer")
H.eq("...then the smallest", accRows[3].name, "Torchlite")

-- The class token is what lets the tooltip colour a name, and it can only be
-- captured while that character is logged in.
H.eq("each character kept its class", accRows[1].class, "MAGE")
H.eq("...", accRows[2].class, "ROGUE")
H.eq("...", accRows[3].class, "DRUID")

-- An alt's numbers are memories, so they carry an age; yours are live bags
-- plus a bank snapshot.
H.check("an alt's row is aged", accRows[2].oldest ~= nil)

-- ---------------------------------------------------------------------------
H.section("when the block only knows about you")
-- ---------------------------------------------------------------------------

-- A character holding none of the item is left out, which is right -- and it
-- makes "no other character has ever been seen" look exactly like "no other
-- character has any". On a fresh install the first is true of EVERY alt, and
-- that is how the account-wide block came to be reported as only ever showing
-- the character you are on.

H.check("one row, and it is you", db.InventoryOnlyYou({ { you = true } }),
        "the block cannot tell you it has nothing else to show")
H.check("one row that is NOT you is not the lonely case",
        not db.InventoryOnlyYou({ { you = nil, name = "Alt" } }),
        "an alt holding some is a real answer, not an empty one")
H.check("two rows is not the lonely case",
        not db.InventoryOnlyYou({ { you = true }, { you = nil } }),
        "it knows about somebody else")
H.check("no rows is not the lonely case either",
        not db.InventoryOnlyYou({}),
        "an empty block draws nothing at all, so it says nothing")
H.check("...and nil is not", not db.InventoryOnlyYou(nil),
        "nil rows must not claim to be a one-character answer")

-- ---------------------------------------------------------------------------
H.section("a character records what it carries on ARRIVAL")
-- ---------------------------------------------------------------------------

-- THE BUG THIS EXISTS FOR. Bags were stored only on BANKFRAME_OPENED and
-- PLAYER_LEAVING_WORLD, so an alt you had not banked or logged out cleanly on
-- had NO record -- and a character with no record is omitted entirely. Leaving
-- is also the less reliable half: alt-F4 and a crash both skip it.
do
    local f = assert(io.open("core/sell.lua", "r"),
                     "run this from the repo root")
    local src = f:read("*a")
    f:close()
    H.check("arriving in the world arms a bag snapshot",
            string.find(src, "sell.ArmBagSnapshot(GetTime and GetTime() or 0)",
                        1, true) ~= nil,
            "one visit to an alt has to be enough to record it")
    H.check("...and leaving still takes one outright",
            string.find(src,
                'A.RegisterEvent("PLAYER_LEAVING_WORLD", function() sell.SnapshotBags() end)',
                1, true) ~= nil,
            "the departing snapshot is what catches what you picked up")
    -- ARMS, not takes. Snapshotting inline here is what made the first attempt
    -- at this fix incomplete -- see the section below.
    H.check("arrival does NOT snapshot inline",
            string.find(src,
                'A.RegisterEvent("PLAYER_ENTERING_WORLD", function() sell.SnapshotBags() end)',
                1, true) == nil,
            "arrival is the worst moment to read bags")
end

-- ---------------------------------------------------------------------------
H.section("an unanswered bag read must not erase a stored one")
-- ---------------------------------------------------------------------------

-- THE BUG THIS EXISTS FOR, and it is the second half of the one above.
--
-- Two characters holding an item in their BAGS were missing from the
-- account-wide tooltip while two holding it in their BANK were present. The
-- asymmetry was the whole clue: bank is written only from BANKFRAME_OPENED, a
-- moment the client can always answer; bags had just gained a second writer on
-- PLAYER_ENTERING_WORLD, which fires at a moment it often cannot. The walk
-- came back {} and {} overwrote a real snapshot, so the character held none of
-- anything and was dropped from the rows -- exactly how it looked on screen.
H.eq("a walk over real containers may be written",
     sell.SnapshotWritable(80), true)
H.eq("a walk that saw no slots may NOT be",
     sell.SnapshotWritable(0), false)
H.eq("...nor may a missing count", sell.SnapshotWritable(nil), false)

-- The second return of the walker is what carries that, so it cannot be
-- guessed at from the counts.
W.SetBags({ [0] = { { link = SILK, count = 4 }, {} } })
local c2, slots2 = sell.CountContainers(sell.BAG_CONTAINERS)
H.eq("the walker reports the slots it saw", slots2, 2)
H.eq("...alongside the counts", c2[4306], 4)

W.SetBags({})
local c3, slots3 = sell.CountContainers(sell.BAG_CONTAINERS)
H.eq("no containers, no slots", slots3, 0)
H.eq("...and no counts", next(c3), nil)

-- Now the property that matters: an empty read cannot destroy a good one.
W.Reset()
A = W.LoadCore()
W.FireAddonLoaded(A)
db, sell = A.db, A.sell
W.AddItem(4306, { name = "Silk Cloth", quality = 1 })
SILK = W.items[4306].link

W.SetBags({ [0] = { { link = SILK, count = 50 } } })
sell.bagsDirty = true
local _, stored = sell.SnapshotBags()
H.eq("a real walk is stored", stored, true)

-- The client goes quiet -- containers report nothing, as they do for the first
-- moments of a session.
W.SetBags({})
sell.bagsDirty = true
local _, stored2 = sell.SnapshotBags()
H.eq("a walk with no slots is refused", stored2, false)
local kept = db.InventoryRows(4306, nil)
H.eq("...and the stored snapshot survives it", kept[1].bags, 50)

-- A character genuinely carrying nothing is a different thing, and IS stored.
W.SetBags({ [0] = { {}, {}, {} } })
sell.bagsDirty = true
local _, stored3 = sell.SnapshotBags()
H.eq("an empty bag with slots is a real answer", stored3, true)
H.eq("...and it does clear the count",
     table.getn(db.InventoryRows(4306, nil)), 0)

-- ---------------------------------------------------------------------------
H.section("the arrival snapshot waits for the bags to go quiet")
-- ---------------------------------------------------------------------------

-- Arrival is the worst moment to read bags. The containers are still arriving
-- and the item data behind GetContainerItemLink resolves for seconds
-- afterwards -- that resolution is what makes BAG_UPDATE storm, and a snapshot
-- taken mid-storm is a partial one. So arrival arms; the driver takes it.
H.eq("nothing armed is idle",
     sell.BagSettleVerdict(1000, nil, nil, 80), "idle")
H.eq("armed but the client has not answered yet",
     sell.BagSettleVerdict(1000, 1000, 1000, 0), "wait")
H.eq("answered, but the bags are still churning",
     sell.BagSettleVerdict(1002, 1000, 1002, 80), "wait")
H.eq("quiet for long enough",
     sell.BagSettleVerdict(1004, 1000, 1000, 80), "take")

-- The churn clock is the LAST touch, not the arm, so a storm pushes it back.
H.eq("a late BAG_UPDATE pushes the snapshot back",
     sell.BagSettleVerdict(1010, 1000, 1009, 80), "wait")

-- ...but not forever. A character parked somewhere with something writing to
-- their bags every second would never see quiet, and never recording anything
-- is a worse failure than recording something imperfect.
H.eq("waiting too long takes what there is",
     sell.BagSettleVerdict(1040, 1000, 1039, 80), "take")
H.eq("...even with the client still silent",
     sell.BagSettleVerdict(1040, 1000, 1039, 0), "take")

-- End to end, on the driven clock.
W.Reset()
A = W.LoadCore()
W.FireAddonLoaded(A)
db, sell = A.db, A.sell
W.AddItem(4306, { name = "Silk Cloth", quality = 1 })
SILK = W.items[4306].link

-- Driven through the DRIVER FRAME, not by calling the step directly, because
-- the wiring is half the feature: arrival has to show the driver, and the
-- driver has to stop once the snapshot is taken.
W.SetBags({})                       -- the client has not answered yet
W.FireEvent(A.frame, "PLAYER_ENTERING_WORLD")
H.check("arrival arms the snapshot", sell.bagArmedAt ~= nil)
H.eq("...and starts the driver", sell.invDriver.shown, true)
H.eq("...and nothing is stored yet",
     table.getn(db.InventoryRows(4306, nil)), 0)

W.Advance(2)
W.Tick(sell.invDriver)
H.eq("a tick with no containers stores nothing",
     table.getn(db.InventoryRows(4306, nil)), 0)
H.eq("...and the driver keeps running", sell.invDriver.shown, true)

-- The bags arrive, item by item, the way the client actually sends them.
W.SetBags({ [0] = { { link = SILK, count = 20 }, {} } })
W.FireEvent(A.frame, "BAG_UPDATE")
W.Advance(2)
W.Tick(sell.invDriver)
H.eq("a tick during the storm stores nothing either",
     table.getn(db.InventoryRows(4306, nil)), 0)

-- STILL STORMING, and now past BAG_SETTLE measured from ARRIVAL. This is the
-- tick that separates a settle clock stamped by BAG_UPDATE from one that only
-- ever knew when the loading screen ended: the second would snapshot here and
-- store the 20 that had resolved, losing the 30 still on its way.
W.FireEvent(A.frame, "BAG_UPDATE")
W.Advance(2)
W.Tick(sell.invDriver)
H.eq("a storm running past the settle window still stores nothing",
     table.getn(db.InventoryRows(4306, nil)), 0)

W.SetBags({ [0] = { { link = SILK, count = 20 },
                    { link = SILK, count = 30 } } })
W.FireEvent(A.frame, "BAG_UPDATE")
W.Advance(4)                        -- quiet at last
W.Tick(sell.invDriver)
local arrived = db.InventoryRows(4306, nil)
H.eq("quiet, so the snapshot is taken", table.getn(arrived), 1)
H.eq("...and it is the WHOLE bag, not the half that had resolved",
     arrived[1].bags, 50)
H.isNil("...and it disarms", sell.bagArmedAt)
H.eq("...and the driver stops", sell.invDriver.shown, false)
H.eq("a step with nothing armed is idle",
     sell.StepBagSnapshot(GetTime()), false)

os.exit(H.report("inventory"))
