-- Aegis: Exchange -- tests/units/postbook_test.lua
--
-- The posting book: what this character put up, so a sale mail can say how
-- many were in the stack.
--
-- WHY IT HAS TO EXIST AT ALL. A sale's quantity is not obtainable from the
-- mailbox. Not in the subject ("Auction successful: <item>"), not in the
-- invoice (GetInboxInvoiceInfo returns a name and prices, no stack size), and
-- a sold auction's mail has no attachment to count -- the buyer got the items.
-- The only moment the number exists is when we posted it.
--
-- WHAT HAS A WRONG ANSWER THAT STILL LOOKS RIGHT:
--
--   * GUESSING. Three stacks of an item up at two different sizes cannot say
--     which one sold, and there is no auction id on 1.12 to ask with. Picking
--     one is a number the player will reconcile against their own mail and
--     find wrong. nil is the answer, and db.RecordTxn already treats absent as
--     unknown rather than as one.
--   * CONSUMING ON A GUESS. Taking a posting out of the book on an ambiguous
--     match throws away the evidence that we guessed.
--   * NOT CONSUMING AN EXPIRY. An auction that came back unsold is not waiting
--     on a sale mail, and leaving it in turns a book of one size into a mixed
--     one -- which costs the NEXT sale its quantity.
--   * LEAKING. One row per posted stack is unbounded for a player who posts
--     all day and never opens their mail.

package.path = "tests/support/?.lua;" .. package.path
local W = require("wow")
local H = require("harness")

W.Reset()
local A = W.LoadCore()
W.FireAddonLoaded(A)
local db = A.db
local sell = A.sell

local DAY = 86400
local NOW = 1700000000

local function reset() db.char.posted = {} end

-- ---------------------------------------------------------------------------
H.section("one stack up, one sale")
-- ---------------------------------------------------------------------------

do
    reset()
    H.check("a posting is remembered",
            db.RecordPosting("Linen Cloth", 2589, 20, NOW))
    H.eq("the sale knows how many", db.MatchPosting("Linen Cloth", NOW), 20)
    -- CONSUMED. A second sale of an item with nothing left up is not the same
    -- stack a second time.
    H.isNil("...and only once", db.MatchPosting("Linen Cloth", NOW))
end

-- An item that was never posted from this character says nothing.
do
    reset()
    H.isNil("an unposted item is unknown", db.MatchPosting("Silk Cloth", NOW))
end

-- ---------------------------------------------------------------------------
H.section("several stacks of one item")
-- ---------------------------------------------------------------------------

-- ALL THE SAME SIZE IS NOT AMBIGUOUS. Which of three identical stacks sold is
-- unanswerable and also the wrong question: the size is the same either way.
do
    reset()
    db.RecordPosting("Linen Cloth", 2589, 20, NOW)
    db.RecordPosting("Linen Cloth", 2589, 20, NOW)
    db.RecordPosting("Linen Cloth", 2589, 20, NOW)
    H.eq("the first sale answers", db.MatchPosting("Linen Cloth", NOW), 20)
    H.eq("...and the second", db.MatchPosting("Linen Cloth", NOW), 20)
    H.eq("...and the third", db.MatchPosting("Linen Cloth", NOW), 20)
    H.isNil("...and then there are none", db.MatchPosting("Linen Cloth", NOW))
end

-- DIFFERENT SIZES ARE. There is no auction id to ask which one sold, so the
-- honest answer is that we do not know.
do
    reset()
    db.RecordPosting("Linen Cloth", 2589, 20, NOW)
    db.RecordPosting("Linen Cloth", 2589, 5, NOW)
    H.isNil("a mixed book cannot say", db.MatchPosting("Linen Cloth", NOW))
    -- ...AND NOTHING WAS CONSUMED. Taking one out on a guess throws away the
    -- evidence that we guessed -- and would make the NEXT sale, of the one
    -- remaining size, answer confidently about the wrong stack.
    H.eq("nothing was consumed", table.getn(db.Postings()), 2)
end

-- One item's stacks do not make ANOTHER item ambiguous.
do
    reset()
    db.RecordPosting("Linen Cloth", 2589, 20, NOW)
    db.RecordPosting("Silk Cloth", 4306, 5, NOW)
    H.eq("the linen answers", db.MatchPosting("Linen Cloth", NOW), 20)
    H.eq("the silk answers", db.MatchPosting("Silk Cloth", NOW), 5)
end

-- ---------------------------------------------------------------------------
H.section("an auction that came back")
-- ---------------------------------------------------------------------------

-- THE POINT OF READING EXPIRY MAIL AT ALL. Post 20, it expires; post 5, it
-- sells. Without consuming the expiry the book holds both sizes and the sale
-- of the 5 cannot say how many it was.
do
    reset()
    db.RecordPosting("Linen Cloth", 2589, 20, NOW)
    db.ExpirePosting("Linen Cloth", NOW)
    db.RecordPosting("Linen Cloth", 2589, 5, NOW)
    H.eq("the sale after an expiry is unambiguous",
         db.MatchPosting("Linen Cloth", NOW), 5)
end

-- ...and without it, it is not. Asserted so the expiry path cannot be removed
-- as redundant.
do
    reset()
    db.RecordPosting("Linen Cloth", 2589, 20, NOW)
    db.RecordPosting("Linen Cloth", 2589, 5, NOW)
    H.isNil("...which it would not be otherwise",
            db.MatchPosting("Linen Cloth", NOW))
end

-- ---------------------------------------------------------------------------
H.section("the book does not grow forever")
-- ---------------------------------------------------------------------------

-- 72h is the longest auction Turtle allows and mail then sits for up to 30
-- days, so a posting older than the two together is a leak and not a record.
do
    reset()
    db.RecordPosting("Old Thing", 1, 20, NOW - 40 * DAY)
    db.RecordPosting("New Thing", 2, 5, NOW - 1 * DAY)
    db.PrunePostings(NOW)
    H.eq("the stale one is gone", table.getn(db.Postings()), 1)
    H.eq("...and the live one is not", db.Postings()[1].name, "New Thing")
end

-- Just inside the window survives, so the cutoff is not a round-down to zero.
do
    reset()
    db.RecordPosting("Just Alive", 1, 20, NOW - 32 * DAY)
    db.PrunePostings(NOW)
    H.eq("a posting inside the window stays", table.getn(db.Postings()), 1)
end

-- A posting with no timestamp cannot be aged, and a record that can never
-- expire is the leak this prune exists to prevent.
do
    reset()
    table.insert(db.Postings(), { name = "Undated", qty = 5 })
    db.PrunePostings(NOW)
    H.eq("an undated posting is dropped", table.getn(db.Postings()), 0)
end

-- THE CAP, for a player who posts all day and never opens their mail. Oldest
-- go first: the newest are the ones a sale is most likely to be about.
do
    reset()
    local i = 1
    while i <= db.POSTED_MAX + 25 do
        db.RecordPosting("Thing " .. i, i, 1, NOW)
        i = i + 1
    end
    H.eq("the book is capped", table.getn(db.Postings()), db.POSTED_MAX)
    H.eq("...and it kept the newest", db.Postings()[db.POSTED_MAX].name,
         "Thing " .. (db.POSTED_MAX + 25))
end

-- ---------------------------------------------------------------------------
H.section("what is not a posting")
-- ---------------------------------------------------------------------------

H.check("no name is not recorded", not db.RecordPosting(nil, 1, 20, NOW))
H.check("an empty name is not", not db.RecordPosting("", 1, 20, NOW))
H.check("no quantity is not", not db.RecordPosting("X", 1, nil, NOW))
H.check("a zero quantity is not", not db.RecordPosting("X", 1, 0, NOW))
H.check("a negative one is not", not db.RecordPosting("X", 1, -3, NOW))

do
    reset()
    db.RecordPosting("X", 1, 2.7, NOW)
    H.eq("a fraction is floored", db.Postings()[1].qty, 2)
end

H.isNil("matching nothing is nothing", db.MatchPosting(nil, NOW))

-- ---------------------------------------------------------------------------
H.section("posting for real, and matching what the mail would say")
-- ---------------------------------------------------------------------------

-- WHY THIS IS HERE. Everything above hands db.RecordPosting a name chosen by
-- the test, so every one of those cases passes no matter WHAT the posting path
-- actually stores. The one thing that cannot be assumed is that the key the
-- poster writes is the key the mailbox will later look up: the mail subject
-- yields a bare item name, and sell.GetItem reads a slot that also knows a
-- LINK and an id. Store the wrong one of those and the whole feature reports
-- unknown for every sale while every test above stays green -- which is very
-- nearly what happened.
--
-- So this posts an item the way the addon does and then matches it the way the
-- mailbox does, with nothing shared between the two but the item itself.
do
    reset()
    W.AddItem(765, { name = "Silverleaf", quality = 1, stackCount = 20,
                     sellPrice = 25, texture = "icon" })
    W.sellSlot = { link = "|cffffffff|Hitem:765:0:0:0|h[Silverleaf]|h|r",
                   count = 5 }

    local it = sell.GetItem()
    H.eq("the slot reports a bare name, not a link", it.name, "Silverleaf")

    H.check("the post goes through", sell.Post(2000, 1000, 480))
    H.eq("...and left exactly one posting", table.getn(db.Postings()), 1)

    -- THE MAILBOX SIDE. "Auction successful: Silverleaf" gives this and only
    -- this -- no link, no id, no count.
    H.eq("the sale mail's bare name matches it",
         db.MatchPosting("Silverleaf"), 5)
end

-- The id is worth carrying too: the ledger uses it for the tooltip on the
-- Sales side, and it is the one field the mail can never supply.
do
    reset()
    W.sellSlot = { link = "|cffffffff|Hitem:765:0:0:0|h[Silverleaf]|h|r",
                   count = 3 }
    sell.Post(2000, 1000, 480)
    H.eq("the posting carries the item id", db.Postings()[1].id, 765)
end

W.sellSlot = nil

-- ---------------------------------------------------------------------------
H.section("the book is reconciled against what is actually up")
-- ---------------------------------------------------------------------------

-- WHY THIS EXISTS. db.RecordPosting only knows about stacks it WATCHED go up.
-- Anything posted before this character had a book -- which is every auction
-- any existing player had up when the feature shipped -- is invisible to it,
-- and every one of those sales lands in the ledger with an unknown quantity.
-- That is how it was reported: sold a Silverleaf, no data. The owner sweep
-- already asks the server what is up; this is folding that answer in.

local function stack(name, id, qty) return { name = name, id = id, qty = qty } end

do
    reset()
    -- An empty book and two stacks up that it has never heard of.
    H.eq("what the server knows is learned",
         db.ReconcilePostings({ stack("Silverleaf", 765, 5),
                                stack("Peacebloom", 2447, 20) }, NOW), 2)
    H.eq("...and the sale can answer", db.MatchPosting("Silverleaf", NOW), 5)
    H.eq("...for both", db.MatchPosting("Peacebloom", NOW), 20)
end

-- IDEMPOTENT, because this runs on EVERY auction house visit. A book that
-- already agrees with the server has nothing to learn.
do
    reset()
    local up = { stack("Silverleaf", 765, 5), stack("Silverleaf", 765, 5) }
    H.eq("the first visit learns both", db.ReconcilePostings(up, NOW), 2)
    H.eq("the second learns nothing", db.ReconcilePostings(up, NOW), 0)
    H.eq("the third learns nothing", db.ReconcilePostings(up, NOW), 0)
    H.eq("...and the book still holds two", table.getn(db.Postings()), 2)
end

-- The failure a naive append would cause, asserted directly: three visits with
-- one stack up must not leave three postings, because all three are the same
-- size and MatchPosting would then answer confidently for two sales that never
-- happened.
do
    reset()
    local up = { stack("Silverleaf", 765, 5) }
    db.ReconcilePostings(up, NOW)
    db.ReconcilePostings(up, NOW)
    db.ReconcilePostings(up, NOW)
    H.eq("one auction is one posting", db.MatchPosting("Silverleaf", NOW), 5)
    H.isNil("...and there is not a second", db.MatchPosting("Silverleaf", NOW))
end

-- TOPPED UP PER SIZE, not per item. Two of five up and one of five known is
-- one to add -- and a twenty that the book has never seen is another, even
-- though the item is already in the book.
do
    reset()
    db.RecordPosting("Silverleaf", 765, 5, NOW)
    H.eq("only the difference is added",
         db.ReconcilePostings({ stack("Silverleaf", 765, 5),
                                stack("Silverleaf", 765, 5),
                                stack("Silverleaf", 765, 20) }, NOW), 2)
    H.eq("the book now holds all three", table.getn(db.Postings()), 3)
end

-- ADDITIVE, NEVER SUBTRACTIVE, and this is the case that makes it matter:
-- the stack sold, the server has already forgotten it, and the sale mail is
-- still sitting unread. Check the AH before the mailbox and a subtractive
-- reconcile would eat the record the mail was about to use.
do
    reset()
    db.RecordPosting("Silverleaf", 765, 5, NOW)
    db.ReconcilePostings({}, NOW)        -- nothing up: it just sold
    H.eq("a sold stack keeps its record", db.MatchPosting("Silverleaf", NOW), 5)
end

-- ...and the same for an item the server does report, but fewer of.
do
    reset()
    db.RecordPosting("Silverleaf", 765, 5, NOW)
    db.RecordPosting("Silverleaf", 765, 5, NOW)
    db.ReconcilePostings({ stack("Silverleaf", 765, 5) }, NOW)
    H.eq("the book is not trimmed to the server", table.getn(db.Postings()), 2)
end

-- A row the client could not identify still has a NAME, and the name is the
-- whole of what a sale mail matches on -- so it is worth recording without an
-- id rather than dropped.
do
    reset()
    H.eq("an id-less row is still learned",
         db.ReconcilePostings({ stack("Silverleaf", nil, 5) }, NOW), 1)
    H.eq("...and answers", db.MatchPosting("Silverleaf", NOW), 5)
end

-- Junk rows are not postings.
do
    reset()
    H.eq("nothing usable is nothing added",
         db.ReconcilePostings({ stack(nil, 1, 5), stack("", 1, 5),
                                stack("X", 1, 0), stack("Y", 1, nil) }, NOW), 0)
    H.eq("...and the book is untouched", table.getn(db.Postings()), 0)
end

H.eq("no list at all is nothing added", db.ReconcilePostings(nil, NOW), 0)

-- The tally both sides are counted with.
do
    local t = db.PostingTally({ stack("A", 1, 5), stack("A", 1, 5),
                                stack("A", 1, 20), stack("B", 2, 1) })
    H.eq("two of A at five", t.A[5], 2)
    H.eq("one of A at twenty", t.A[20], 1)
    H.eq("one of B at one", t.B[1], 1)
    H.isNil("and nothing of C", t.C)
end

-- ---------------------------------------------------------------------------
H.section("...and the sweep actually feeds it")
-- ---------------------------------------------------------------------------

-- THE HALF A PURE FUNCTION CANNOT PROVE. ReconcilePostings can be perfect and
-- change nothing on screen if no one calls it with real auctions. The owner
-- sweep is the only place the server states stack sizes, so it is driven here
-- end to end: set up auctions, run the sweep, and ask the book.
do
    reset()
    db.char.posted = {}
    W.SetOwned({
        { name = "Silverleaf", count = 5, buyout = 10000,
          link = "|cffffffff|Hitem:765:0:0:0|h[Silverleaf]|h|r" },
        { name = "Peacebloom", count = 20, buyout = 40000,
          link = "|cffffffff|Hitem:2447:0:0:0|h[Peacebloom]|h|r" },
    })
    sell.StartOwnerSweep()
    local guard = 0
    while sell.ownerSweep and guard < 10 do
        sell.OwnerSweepStep()
        guard = guard + 1
    end
    H.check("the sweep finished", sell.ownerSweep == nil)
    H.eq("the sweep taught the book the stack size",
         db.MatchPosting("Silverleaf"), 5)
    H.eq("...for every auction up", db.MatchPosting("Peacebloom"), 20)
end

-- An empty auction book is not a reason to forget anything.
do
    reset()
    db.RecordPosting("Silverleaf", 765, 5, NOW)
    W.SetOwned({})
    sell.StartOwnerSweep()
    local guard = 0
    while sell.ownerSweep and guard < 10 do
        sell.OwnerSweepStep(); guard = guard + 1
    end
    H.eq("a sweep with nothing up keeps the book",
         db.MatchPosting("Silverleaf", NOW), 5)
end

-- ---------------------------------------------------------------------------
H.section("...and the real paths actually use it")
-- ---------------------------------------------------------------------------

-- A BOOK NOTHING WRITES TO IS A TESTED FUNCTION AND AN UNCHANGED SCREEN. Both
-- ways of posting have to record, and the mail scan has to match -- the
-- arithmetic above is correct either way.
do
    local function body(path)
        local f = assert(io.open(path, "r"), "run this from the repo root")
        local src = f:read("*a")
        f:close()
        return src
    end
    local sellSrc = body("core/sell.lua")
    local uiSrc = body("ui/frame.lua")
    local function says(src, needle)
        return string.find(src, needle, 1, true) ~= nil
    end

    H.check("posting one stack remembers it",
            says(sellSrc, "A.db.RecordPosting(it.name, it.itemId, count)"))
    -- ONE PER StartAuction, or a run of ten stacks leaves nine sales unable to
    -- say how many they were.
    H.check("...and so does every stack of a multi-post",
            says(sellSrc,
                 "A.db.RecordPosting(it.name, job.itemId, job.stackSize)"))

    H.check("a sale mail matches against it",
            says(uiSrc, "local qty = A.db.MatchPosting(item)"))
    H.check("...and passes the count to the ledger",
            says(uiSrc,
                 'A.db.RecordTxn("sale", item, money, A.db.IdFromName(item), qty)'))
    H.check("an expiry gives the posting back",
            says(uiSrc, "A.db.ExpirePosting(back)"))

    -- GetInboxInvoiceInfo MARKS THE MAIL AS READ, which shortens its timeout.
    -- In an inbox walk that would do it to every mail in the box, including
    -- mail Aegis has nothing to do with. Data loss, not lag.
    --
    -- SCOPED TO THE WALK, and looking for a CALL. The rule is not "never" --
    -- opening one mail is exactly where it belongs -- and the name appears in
    -- a comment right there explaining why it is not called, which a whole-file
    -- search for the bare name matches.
    local at = string.find(uiSrc, "function ui.ScanMailSales(", 1, true)
    local stop = string.find(uiSrc, "\nend\n", at, true)
    local walk = string.sub(uiSrc, at, stop)
    H.check("the inbox walk never CALLS the invoice API",
            string.find(walk, "GetInboxInvoiceInfo(", 1, true) == nil,
            "it reads the mail, which shortens every mail's life")
end

os.exit(H.report("postbook"))
